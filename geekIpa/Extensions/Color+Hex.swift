//
//  Color+Hex.swift
//  geekIpa
//
//  Color 的十六进制构造与导出。
//  说明：这两个扩展原先由本地包 AltSourceKit 提供；该包已随源商店功能移除，
//  因此在本项目内自带一份实现（行为与原先一致，且不依赖 iOS 17 的 resolve(in:)）。
//

import SwiftUI
import UIKit

extension Color {

	/// 用 "#RRGGBB" / "RRGGBB" / "#RGB" / "#RRGGBBAA" 构造颜色
	init(hex: String) {
		let (r, g, b, a) = Self._rgba(from: hex)
		self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
	}

	/// 导出为 "#RRGGBB"（alpha 为 true 时 "#RRGGBBAA"）
	func toHex(alpha: Bool = false) -> String {
		let ui = UIColor(self)
		var r: CGFloat = 0
		var g: CGFloat = 0
		var b: CGFloat = 0
		var a: CGFloat = 0
		guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else {
			return alpha ? "#00000000" : "#000000"
		}
		let ri = Int((r * 255).rounded())
		let gi = Int((g * 255).rounded())
		let bi = Int((b * 255).rounded())
		let ai = Int((a * 255).rounded())
		if alpha {
			return String(format: "#%02X%02X%02X%02X", ri, gi, bi, ai)
		}
		return String(format: "#%02X%02X%02X", ri, gi, bi)
	}

	// MARK: - 解析

	private static func _rgba(from hex: String) -> (Double, Double, Double, Double) {
		var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
		if s.hasPrefix("#") { s.removeFirst() }
		if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }

		// 统一成 hex 数字
		var value: UInt64 = 0
		guard Scanner(string: s).scanHexInt64(&value) else {
			return (0, 0, 0, 1)
		}

		switch s.count {
		case 3: // RGB
			let r = (value >> 8) & 0xF
			let g = (value >> 4) & 0xF
			let b = value & 0xF
			return (Double(r * 17) / 255, Double(g * 17) / 255, Double(b * 17) / 255, 1)
		case 6: // RRGGBB
			let r = (value >> 16) & 0xFF
			let g = (value >> 8) & 0xFF
			let b = value & 0xFF
			return (Double(r) / 255, Double(g) / 255, Double(b) / 255, 1)
		case 8: // RRGGBBAA（与原 AltSourceKit 实现一致）
			let r = (value >> 24) & 0xFF
			let g = (value >> 16) & 0xFF
			let b = (value >> 8) & 0xFF
			let a = value & 0xFF
			return (Double(r) / 255, Double(g) / 255, Double(b) / 255, Double(a) / 255)
		default:
			return (0, 0, 0, 1)
		}
	}
}
