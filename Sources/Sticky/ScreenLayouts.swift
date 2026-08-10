import AppKit
import Foundation

/// The position of one note within one screen configuration.
///
/// This is an overlay on top of the model: `Note.frame`/`tuckedEdge`/`tuckedY` remain the
/// source for the *active* configuration, this table keeps what belongs to the other ones.
struct NoteLayoutEntry: Codable, Equatable, Sendable {
    var frame: CGRect
    var tuckedEdge: TuckEdge?
    var tuckedY: CGFloat

    init(frame: CGRect, tuckedEdge: TuckEdge?, tuckedY: CGFloat) {
        self.frame = frame
        self.tuckedEdge = tuckedEdge
        self.tuckedY = tuckedY
    }

    init(_ note: Note) {
        self.init(frame: note.frame, tuckedEdge: note.tuckedEdge, tuckedY: note.tuckedY)
    }

    private enum CodingKeys: String, CodingKey {
        case frame, tuckedEdge, tuckedY
    }

    /// Same approach as with `Note`: every field with `decodeIfPresent`, so that an older
    /// `layouts.json` keeps loading if a field is ever added.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frame = try container.decodeIfPresent(CGRect.self, forKey: .frame) ?? Note.defaultFrame
        tuckedEdge = try container.decodeIfPresent(TuckEdge.self, forKey: .tuckedEdge)
        tuckedY = try container.decodeIfPresent(CGFloat.self, forKey: .tuckedY) ?? 0
    }
}

/// Determines a stable key for the current screen configuration.
@MainActor
enum ScreenConfiguration {

    /// Key for the attached screens.
    ///
    /// Per screen we take the *physical* identity (vendor/model/serial number via CoreGraphics)
    /// plus the position and size in the global coordinate system. The `CGDirectDisplayID`
    /// itself is deliberately not the basis: it is handed out on connect and can differ every
    /// time, whereas vendor/model/serial number are attached to the screen itself and thus
    /// survive a dock/undock and a restart. The list is sorted on position, so the order in
    /// which `NSScreen.screens` returns the screens does not matter.
    ///
    /// Limitation: rearranging screens in System Settings (or a different resolution) yields
    /// a new key. That is intentional; that *is* a different configuration.
    static func currentKey() -> String {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return "no-screens" }

        var entries: [Entry] = []
        for screen in screens {
            let frame = screen.frame
            let text = identity(of: screen) + "@" + describe(frame)
            entries.append(Entry(x: frame.minX, y: frame.minY, text: text))
        }
        entries.sort { left, right in
            left.x == right.x ? left.y < right.y : left.x < right.x
        }

        return entries.map(\.text).joined(separator: "|")
    }

    private struct Entry {
        let x: CGFloat
        let y: CGFloat
        let text: String
    }

    private static func identity(of screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let displayID = CGDirectDisplayID(number?.uint32Value ?? 0)
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        // If CoreGraphics reports nothing usable, only the display id is left.
        if vendor == 0 && model == 0 && serial == 0 {
            return "id\(displayID)"
        }
        return "\(vendor)-\(model)-\(serial)"
    }

    private static func describe(_ frame: CGRect) -> String {
        "\(Int(frame.width))x\(Int(frame.height))+\(Int(frame.minX))+\(Int(frame.minY))"
    }
}
