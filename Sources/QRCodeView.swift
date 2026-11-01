import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct QRCodeView: View {
    let text: String
    var size: CGFloat = 190

    private let q0 = CIContext()
    private let q1 = CIFilter.qrCodeGenerator()

    var body: some View {
        Group {
            if let image = q2 {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode")
                    .resizable()
                    .scaledToFit()
                    .padding(30)
                    .foregroundStyle(PhoenixTheme.muted)
            }
        }
        .frame(width: size, height: size)
        .padding(12)
        .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var q2: UIImage? {
        q1.message = Data(text.utf8)
        q1.correctionLevel = "M"
        guard let output = q1.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = q0.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

