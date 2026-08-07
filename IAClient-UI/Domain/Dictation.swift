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

    private let log = Logger(subsystem: "hublot", category: "dictation")

    /// Au-delà, on arrête tout seul : un enregistrement oublié dans la poche
    /// ferait un fichier de plusieurs mégaoctets pour rien.
    private static let limit = Duration.seconds(180)

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
            recorder.record()

            self.recorder = recorder
            self.file = url
            elapsed = .zero
            phase = .recording
            ticker = Task { [weak self] in await self?.tick() }
        } catch {
            log.error("micro indisponible : \(error.localizedDescription, privacy: .public)")
            phase = .failed("Micro indisponible.")
        }
    }

    /// Arrête et rend l'audio. `nil` si rien d'exploitable n'a été capté.
    func stop() -> Data? {
        ticker?.cancel()
        ticker = nil
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        defer { file = nil }
        guard let file, let data = try? Data(contentsOf: file) else {
            phase = .idle
            return nil
        }
        try? FileManager.default.removeItem(at: file)

        // Un appui malencontreux produit un fichier d'en-tête et rien d'autre.
        // Le monter jusqu'à Groq pour s'entendre répondre du vide serait une
        // seconde d'attente offerte à personne.
        guard elapsed > .milliseconds(600), data.count > 2_000 else {
            phase = .idle
            return nil
        }
        phase = .transcribing
        return data
    }

    func cancel() {
        ticker?.cancel()
        ticker = nil
        recorder?.stop()
        recorder = nil
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

    // MARK: Interne

    private func tick() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, phase == .recording else { return }
            elapsed += .milliseconds(200)
            if elapsed >= Self.limit { return }
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
