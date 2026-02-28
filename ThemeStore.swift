// ThemeStore.swift
// TaskHubMobile
// Stores user-customizable colors for Work and Personal, persisted to the shared App Group so widgets/extensions can read them.

import SwiftUI
import Combine
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Server-backed transition is now the source of truth for area text coloring preferences.

@MainActor
final class ThemeStore: ObservableObject {
    // Server-backed preferences (cached)
    @Published var areaTextColoringEnabled: Bool
    @Published var workAreaTextHex: String
    @Published var personalAreaTextHex: String

    // Derived from server-backed hex values. Do not persist independently.
    @Published var workColor: Color
    @Published var personalColor: Color

    private let defaults: UserDefaults
    private let appGroupID: String = AppIdentifiers.appGroupID

    private let enabledKey = "theme.area_text_coloring_enabled"
    private let workHexKey = "theme.work_hex"
    private let personalHexKey = "theme.personal_hex"

    struct RGBA: Codable { let r: Double; let g: Double; let b: Double; let a: Double }
    struct ThemeOut: Codable { let enabled: Bool; let work: RGBA; let personal: RGBA }

    init() {
        if let suite = UserDefaults(suiteName: appGroupID) {
            self.defaults = suite
        } else {
            self.defaults = .standard
        }

        let defaultEnabled = false
        let defaultWorkHex = "#93c5fd"
        let defaultPersonalHex = "#86efac"

        // Load cached values into locals first to avoid using self before full initialization
        let enabledCached = defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
        let workHexCached = defaults.string(forKey: workHexKey) ?? defaultWorkHex
        let personalHexCached = defaults.string(forKey: personalHexKey) ?? defaultPersonalHex

        let defaultWork = ThemeStore.hexToColor(defaultWorkHex) ?? Color(red: 0.58, green: 0.77, blue: 0.99)
        let defaultPersonal = ThemeStore.hexToColor(defaultPersonalHex) ?? Color(red: 0.52, green: 0.94, blue: 0.67)
        let initialWorkColor = ThemeStore.hexToColor(workHexCached) ?? defaultWork
        let initialPersonalColor = ThemeStore.hexToColor(personalHexCached) ?? defaultPersonal

        // Now assign all stored properties
        self.areaTextColoringEnabled = enabledCached
        self.workAreaTextHex = workHexCached
        self.personalAreaTextHex = personalHexCached
        self.workColor = initialWorkColor
        self.personalColor = initialPersonalColor

        // Ensure theme.json exists for extensions
        save()
    }

    func save() {
        // Persist to UserDefaults (App Group when available)
        defaults.set(areaTextColoringEnabled, forKey: enabledKey)
        defaults.set(workAreaTextHex, forKey: workHexKey)
        defaults.set(personalAreaTextHex, forKey: personalHexKey)
        defaults.synchronize()

        // Export a lightweight theme.json to the App Group container root
        exportThemeJSON()
    }

    private func exportThemeJSON() {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        let url = container.appendingPathComponent("theme.json")

        let out = ThemeOut(
            enabled: areaTextColoringEnabled,
            work: ThemeStore.colorToRGBA(workColor),
            personal: ThemeStore.colorToRGBA(personalColor)
        )
        if let data = try? JSONEncoder().encode(out) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    // MARK: - Server Sync Helpers

    /// Update cached values from server preferences (camelCase fields)
    func applyServerPreferences(areaTextColoringEnabled: Bool?, workAreaTextColor: String?, personalAreaTextColor: String?) {
        if let enabled = areaTextColoringEnabled { self.areaTextColoringEnabled = enabled }
        if let workHex = workAreaTextColor, ThemeStore.isValidHexRGB(workHex) { self.workAreaTextHex = workHex }
        if let personalHex = personalAreaTextColor, ThemeStore.isValidHexRGB(personalHex) { self.personalAreaTextHex = personalHex }
        // Recompute derived colors
        let defaultWork = ThemeStore.hexToColor("#93c5fd") ?? Color(red: 0.58, green: 0.77, blue: 0.99)
        let defaultPersonal = ThemeStore.hexToColor("#86efac") ?? Color(red: 0.52, green: 0.94, blue: 0.67)
        self.workColor = ThemeStore.hexToColor(self.workAreaTextHex) ?? defaultWork
        self.personalColor = ThemeStore.hexToColor(self.personalAreaTextHex) ?? defaultPersonal
        save()
    }

    /// Build a dictionary suitable for PATCH payload with only changed fields.
    func diffPayload(currentServerEnabled: Bool?, currentServerWorkHex: String?, currentServerPersonalHex: String?) -> [String: Any] {
        var payload: [String: Any] = [:]
        if currentServerEnabled == nil || currentServerEnabled != areaTextColoringEnabled { payload["area_text_coloring_enabled"] = areaTextColoringEnabled }
        if currentServerWorkHex == nil || currentServerWorkHex != workAreaTextHex { payload["work_area_text_color"] = workAreaTextHex }
        if currentServerPersonalHex == nil || currentServerPersonalHex != personalAreaTextHex { payload["personal_area_text_color"] = personalAreaTextHex }
        return payload
    }

    // MARK: - Hex Utilities

    static func isValidHexRGB(_ hex: String) -> Bool {
        let pattern = "^#?[A-Fa-f0-9]{6}$"
        return hex.range(of: pattern, options: .regularExpression) != nil
    }

    static func hexToRGBA(_ hex: String) -> RGBA? {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return RGBA(r: r, g: g, b: b, a: 1.0)
    }

    static func hexToColor(_ hex: String) -> Color? {
        guard let rgba = hexToRGBA(hex) else { return nil }
        return rgbaToColor(rgba)
    }

    // MARK: - Color Conversion
    static func colorToRGBA(_ color: Color) -> RGBA {
        #if canImport(UIKit)
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if ui.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return RGBA(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
        } else if let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
                  let converted = ui.cgColor.converted(to: sRGB, intent: .defaultIntent, options: nil),
                  let comps = converted.components, comps.count >= 4 {
            return RGBA(r: Double(comps[0]), g: Double(comps[1]), b: Double(comps[2]), a: Double(comps[3]))
        } else {
            return RGBA(r: 0, g: 0, b: 0, a: 1)
        }
        #else
        return RGBA(r: 0, g: 0, b: 0, a: 1)
        #endif
    }

    static func rgbaToColor(_ rgba: RGBA) -> Color {
        #if canImport(UIKit)
        let ui = UIColor(red: CGFloat(rgba.r), green: CGFloat(rgba.g), blue: CGFloat(rgba.b), alpha: CGFloat(rgba.a))
        return Color(uiColor: ui)
        #else
        let cg = CGColor(srgbRed: CGFloat(rgba.r), green: CGFloat(rgba.g), blue: CGFloat(rgba.b), alpha: CGFloat(rgba.a))
        return Color(cgColor: cg)
        #endif
    }

    static func colorToHexRGB(_ color: Color) -> String? {
        let rgba = colorToRGBA(color)
        let r = max(0, min(255, Int(round(rgba.r * 255.0))))
        let g = max(0, min(255, Int(round(rgba.g * 255.0))))
        let b = max(0, min(255, Int(round(rgba.b * 255.0))))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

