//
//  Attachment.swift
//  Hublot
//
//  Une image jointe à une demande.
//
//  Le format est arrêté ici, une fois pour toutes : du JPEG, borné en taille,
//  et rien d'autre. Ce n'est pas une simplification par paresse — c'est la
//  seule forme que les deux moteurs lisent sans discuter, et la seule qui tienne
//  dans une trame WebSocket sans transformer l'envoi d'une capture d'écran en
//  transfert de fichier.
//

import Foundation
import UIKit

nonisolated struct Attachment: Identifiable, Hashable, Sendable {
    let id = UUID()
    /// L'image, déjà réduite et encodée.
    let jpeg: Data

    var mimeType: String { "image/jpeg" }

    /// Le bloc ACP correspondant.
    var block: ContentBlock {
        .image(mimeType: mimeType, data: jpeg.base64EncodedString())
    }

    /// « 184 ko » — l'ordre de grandeur, pour savoir ce qu'on s'apprête à
    /// envoyer depuis un réseau mobile.
    var size: String {
        let bytes = jpeg.count
        return bytes < 1024
            ? "\(bytes) o"
            : String(format: "%.0f ko", Double(bytes) / 1024)
    }

    /// Le côté le plus long, en pixels, après réduction.
    ///
    /// 1568 n'est pas un chiffre rond par hasard : c'est la taille au-delà de
    /// laquelle les modèles de vision d'Anthropic redimensionnent eux-mêmes.
    /// Envoyer plus gros ne fait pas voir mieux — cela ne fait que payer la
    /// bande passante d'un téléphone pour un travail refait à l'arrivée.
    private static let maxSide: CGFloat = 1568

    /// La qualité JPEG. À 0,8 l'artefact est invisible sur une capture d'écran
    /// de terminal, qui est le cas d'usage réel ici.
    private static let quality: CGFloat = 0.8

    /// Prépare une image venue de la photothèque.
    ///
    /// Le décodage et le redimensionnement se font hors du fil principal : une
    /// photo de 12 Mpx bloque l'interface une bonne fraction de seconde, et
    /// c'est exactement le moment où l'utilisateur regarde l'écran.
    static func make(from data: Data) async -> Attachment? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return nil }
            let reduced = downscale(image)
            guard let jpeg = reduced.jpegData(compressionQuality: quality) else { return nil }
            return Attachment(jpeg: jpeg)
        }.value
    }

    private static func downscale(_ image: UIImage) -> UIImage {
        let side = max(image.size.width, image.size.height)
        guard side > maxSide else { return image }
        let scale = maxSide / side
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        // Échelle 1 imposée : sans elle le rendu multiplie par la densité de
        // l'écran et rend une image trois fois plus grande que demandée.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
