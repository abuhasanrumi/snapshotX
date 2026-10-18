import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An editable capture: the original pixels plus every annotation, the crop and the background.
struct ProjectFile: Codable {
    static let fileExtension = "snapshotx"
    static var contentType: UTType { UTType(filenameExtension: fileExtension) ?? .json }

    struct DecodeError: LocalizedError {
        var errorDescription: String? { "This isn't a valid SnapShotX project file." }
    }

    var version = 1
    var image: Data
    var state: EditorState

    static func encode(image: CGImage, state: EditorState) throws -> Data {
        guard let png = ImageFile.pngData(image) else { throw ImageFile.WriteError() }
        return try JSONEncoder().encode(ProjectFile(image: png, state: state))
    }

    static func decode(_ data: Data) throws -> (image: CGImage, state: EditorState) {
        let file = try JSONDecoder().decode(ProjectFile.self, from: data)
        guard let source = CGImageSourceCreateWithData(file.image as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw DecodeError() }
        return (image, file.state)
    }
}
