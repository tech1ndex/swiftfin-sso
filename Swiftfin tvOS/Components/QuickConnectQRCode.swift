//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct QuickConnectQRCode: View {
    let serverURL: URL

    var body: some View {
        if let image = Self.image(for: serverURL) {
            VStack(spacing: 20) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 300, height: 300)
                Text("Scan with your phone")
                    .font(.caption)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Open the Jellyfin server on your phone"))
            .accessibilityValue(Text(verbatim: serverURL.host ?? ""))
        }
    }

    private static let context = CIContext()

    static func image(for serverURL: URL) -> CGImage? {
        // The phone signs in independently. Only the installation URL belongs in the QR.
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil
        else { return nil }
        components.query = nil
        components.fragment = nil
        guard let destination = components.url else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(destination.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let symbol = filter.outputImage else { return nil }

        // Include a four-module quiet zone even when the pairing screen uses a dark background.
        let bounds = symbol.extent.insetBy(dx: -4, dy: -4)
        let paper = CIImage(color: .white).cropped(to: bounds)
        return context.createCGImage(symbol.composited(over: paper), from: bounds)
    }
}
