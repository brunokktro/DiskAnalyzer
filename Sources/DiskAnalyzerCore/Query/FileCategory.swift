import Foundation

/// Coarse type buckets used by filters and treemap colors. Derived from the file
/// extension only, so classification never touches file contents.
public enum FileCategory: String, CaseIterable, Sendable, Identifiable, Hashable {
    case folder, package, image, video, audio, document, archive, diskImage, code, application, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .folder: "Folders"
        case .package: "Packages"
        case .image: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .document: "Documents"
        case .archive: "Archives"
        case .diskImage: "Disk Images"
        case .code: "Code & Data"
        case .application: "Apps"
        case .other: "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .folder: "folder"
        case .package: "shippingbox"
        case .image: "photo"
        case .video: "film"
        case .audio: "music.note"
        case .document: "doc.text"
        case .archive: "archivebox"
        case .diskImage: "externaldrive"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .application: "app.dashed"
        case .other: "doc"
        }
    }

    private static let byExtension: [String: FileCategory] = {
        var map: [String: FileCategory] = [:]
        func add(_ category: FileCategory, _ extensions: String) {
            for ext in extensions.split(separator: " ") { map[String(ext)] = category }
        }
        add(.image, "jpg jpeg png gif heic heif tif tiff bmp webp raw cr2 cr3 nef arw dng psd svg ico icns avif")
        add(.video, "mov mp4 m4v avi mkv wmv flv webm mpg mpeg 3gp mts m2ts prores")
        add(.audio, "mp3 m4a aac wav aif aiff flac ogg opus caf alac mid midi")
        add(.document, "pdf doc docx xls xlsx ppt pptx pages numbers key txt rtf md csv odt ods odp epub tex")
        add(.archive, "zip gz tgz bz2 xz zst 7z rar tar lz4 cpio xip")
        add(.diskImage, "dmg iso img sparseimage sparsebundle vmdk qcow2 vdi vhd vhdx")
        add(.code, "swift c h m mm cpp hpp py js ts jsx tsx java kt go rs rb php sh zsh json yaml yml xml toml sql db sqlite sqlite3 log plist o a dylib so")
        add(.application, "app pkg mpkg appex framework bundle plugin kext")
        return map
    }()

    public static func classify(name: String, kind: NodeKind, isPackage: Bool) -> FileCategory {
        let ext = (name as NSString).pathExtension.lowercased()
        switch kind {
        case .directory:
            if let mapped = byExtension[ext], mapped == .application || mapped == .diskImage { return mapped }
            return isPackage ? .package : .folder
        case .file:
            return byExtension[ext] ?? .other
        case .symlink, .other:
            return .other
        }
    }

    public static func classify(_ node: FileNode) -> FileCategory {
        classify(name: node.name, kind: node.kind, isPackage: node.isPackage)
    }
}
