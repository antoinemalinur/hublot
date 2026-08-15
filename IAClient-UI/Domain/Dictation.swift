//
//  Dictation.swift
//  Hublot
//
//  Dicter plutôt que taper.
//
//  Sur un téléphone, formuler une demande à un agent coûte cher au pouce : ce
//  qu'on écrirait en dix secondes au clavier en prend soixante debout dans le
//  métro. La voix lève exactement cet obstacle-là.
//
//  Deux partis pris.
//
//  **La transcription se fait sur le VPS.** L'audio part par la liaison déjà
//  ouverte, le serveur appelle Groq, le texte revient. La clé Groq reste donc
//  là où elle est déjà — dans l'environnement du service — et pas dans un
//  binaire iOS d'où l'on ne pourrait ni la changer ni la révoquer.
//
//  **Le texte atterrit dans la zone de saisie, pas dans le fil.** On relit avant
//  d'instruire un agent qui a un shell root sur la machine. Une dictée mal
//  comprise qui part directement, c'est une commande qu'on n'a jamais formulée.
//

import AVFoundation
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class Dictation {

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case refused
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// La durée écoulée, pour que l'écran montre que ça enregistre vraiment.
    private(set) var elapsed: Duration = .zero

    var isBusy: Bool { phase == .recording || phase == .transcribing }

    private var recorder: AVAudioRecorder?
    private var ticker: Task<Void, Never>?
    private var file: URL?
    private var closing: RecorderDelegate?

    /// Vrai quand l'enregistrement s'est arrêté de lui-même sur la limite. La
    /// zone de saisie le dit, au lieu de continuer à afficher « j'écoute »
    /// devant un micro déjà coupé.
    private(set) var reachedLimit = false

    private let log = Logger(subsystem: "hublot", category: "dictation")

    /// Au-delà, on arrête tout seul : un enregistrement oublié dans la poche
    /// ferait un fichier de plusieurs mégaoctets pour rien.
    private static let limit = Duration.seconds(180)

    init() {}

    #if DEBUG
        /// Une phase imposée, pour les écrans témoins.
        ///
        /// Le micro lui-même sort de l'app — l'autorisation système n'est pas
        /// pilotable par XCUITest. Ce que l'app **dit** d'un micro refusé, si :
        /// l'invite qui renvoie aux Réglages est un texte de cette app, et rien
        /// ne le vérifiait.
        init(debugPhase: Phase) {
            phase = debugPhase
        }
    #endif

    // MARK: Enregistrement

    func start() async {
        guard phase != .recording else { return }
        guard await Self.authorised() else {
            phase = .refused
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("dictee-\(UUID().uuidString).m4a")
            // 16 kHz mono : c'est la fréquence à laquelle Whisper travaille de
            // toute façon. Enregistrer plus fin ne gagne pas un mot et
            // multiplie le poids de ce qui monte depuis un réseau mobile.
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ])
            // La limite est confiée au recorder plutôt qu'à notre minuteur : le
            // nôtre se contentait de cesser de compter, et l'enregistrement,
            // lui, continuait indéfiniment derrière un compteur figé à 3:00.
            let closing = RecorderDelegate()
            recorder.delegate = closing
            recorder.record(forDuration: Self.limit.seconds)

            self.recorder = recorder
            self.closing = closing
            self.file = url
            elapsed = .zero
            reachedLimit = false
            phase = .recording
            ticker = Task { [weak self] in await self?.tick() }
        } catch {
            log.error("micro indisponible : \(error.localizedDescription, privacy: .public)")
            phase = .failed("Micro indisponible.")
        }
    }

    /// Arrête et rend l'audio. `nil` si rien d'exploitable n'a été capté.
    ///
    /// **Elle attend** que le fichier soit vraiment écrit, et c'est tout son
    /// intérêt. `AVAudioRecorder.stop()` rend la main avant que l'AAC soit
    /// clos : il reste à vider le dernier tampon et à poser l'index du
    /// conteneur `m4a`. Lire le fichier dans la foulée donnait un enregistrement
    /// amputé de sa fin — et d'autant plus amputé que la dictée était longue.
    /// Groq transcrivait fidèlement ce qu'on lui envoyait ; c'est nous qui lui
    /// envoyions une phrase coupée.
    func stop() async -> Data? {
        ticker?.cancel()
        ticker = nil

        guard let recorder, let closing, let file else {
            phase = .idle
            self.file = nil
            return nil
        }
        // L'écran doit montrer la transcription en cours pendant qu'on attend
        // la fermeture du fichier : c'est court, mais ce n'est plus l'écoute.
        phase = .transcribing
        if recorder.isRecording { recorder.stop() }
        await closing.finished()

        self.recorder = nil
        self.closing = nil
        self.file = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        defer { try? FileManager.default.removeItem(at: file) }
        guard let data = try? Data(contentsOf: file) else {
            phase = .idle
            return nil
        }

        // Un appui malencontreux produit un fichier d'en-tête et rien d'autre.
        // Le monter jusqu'à Groq pour s'entendre répondre du vide serait une
        // seconde d'attente offerte à personne.
        guard elapsed > .milliseconds(600), data.count > 2_000 else {
            phase = .idle
            return nil
        }
        log.info("dictée de \(self.caption, privacy: .public) — \(data.count) octets")
        return data
    }

    func cancel() {
        ticker?.cancel()
        ticker = nil
        recorder?.stop()
        recorder = nil
        closing = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .idle
    }

    func settle(_ failure: String? = nil) {
        phase = failure.map { .failed($0) } ?? .idle
    }

    /// « 0:07 » — la durée écoulée, à la seconde.
    var caption: String {
        let seconds = Int(elapsed.components.seconds)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Ce que fait le micro, en trois mots. Affirmer « j'écoute » devant un
    /// enregistrement arrêté par la limite serait faux — et c'est exactement ce
    /// qu'affichait un compteur figé à 3:00.
    var listening: String { reachedLimit ? "limite atteinte" : "j'écoute" }

    // MARK: Interne

    private func tick() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, phase == .recording else { return }
            elapsed += .milliseconds(200)
            if elapsed >= Self.limit {
                reachedLimit = true
                return
            }
        }
    }

    /// Le témoin de fermeture du fichier.
    ///
    /// `AVAudioRecorder` ne rend cette information que par délégué : il n'existe
    /// aucune propriété à interroger, et aucune durée d'attente qu'on puisse
    /// choisir sans se tromper. C'est donc la seule façon correcte de savoir
    /// que l'enregistrement est complet sur le disque.
    @MainActor
    private final class RecorderDelegate: NSObject, AVAudioRecorderDelegate {
        private var waiting: CheckedContinuation<Void, Never>?
        private var isDone = false

        /// Rend la main quand le fichier est clos — tout de suite s'il l'est
        /// déjà, ce qui est le cas quand la limite a coupé l'enregistrement
        /// avant qu'on y touche.
        func finished() async {
            guard !isDone else { return }
            await withCheckedContinuation { continuation in
                if isDone {
                    continuation.resume()
                } else {
                    waiting = continuation
                }
            }
        }

        private func complete() {
            isDone = true
            waiting?.resume()
            waiting = nil
        }

        nonisolated func audioRecorderDidFinishRecording(
            _ recorder: AVAudioRecorder, successfully flag: Bool
        ) {
            Task { @MainActor in self.complete() }
        }

        nonisolated func audioRecorderEncodeErrorDidOccur(
            _ recorder: AVAudioRecorder, error: (any Error)?
        ) {
            Task { @MainActor in self.complete() }
        }
    }

    private static func authorised() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
    }
}
