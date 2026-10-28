//
//  GeekTheme.swift
//  geekIpa
//
//  设计 token（规格书 §1.3/§1.4 的唯一实现处）+ 全局 Toast。
//  所有新界面必须用这里的语义色，禁止硬编码单色值。
//

import SwiftUI
import UIKit

// MARK: - 语义色（规格书 §1.3 token 表）

extension Color {
	/// 主色：浅色 #2563EB / 深色 #3B82F6（主操作按钮、选中态、进度条）
	static let geekPrimary = Color(UIColor { $0.userInterfaceStyle == .dark
		? UIColor(red: 0x3B/255, green: 0x82/255, blue: 0xF6/255, alpha: 1)
		: UIColor(red: 0x25/255, green: 0x63/255, blue: 0xEB/255, alpha: 1) })

	/// 成功：#16A34A / #22C55E
	static let geekSuccess = Color(UIColor { $0.userInterfaceStyle == .dark
		? UIColor(red: 0x22/255, green: 0xC5/255, blue: 0x5E/255, alpha: 1)
		: UIColor(red: 0x16/255, green: 0xA3/255, blue: 0x4A/255, alpha: 1) })

	/// 警示（证书临期 ≤30 天）：#D97706 / #F59E0B
	static let geekWarning = Color(UIColor { $0.userInterfaceStyle == .dark
		? UIColor(red: 0xF5/255, green: 0x9E/255, blue: 0x0B/255, alpha: 1)
		: UIColor(red: 0xD9/255, green: 0x77/255, blue: 0x06/255, alpha: 1) })

	/// 危险（删除、失败、过期、注入插件）：#DC2626 / #EF4444
	static let geekDanger = Color(UIColor { $0.userInterfaceStyle == .dark
		? UIColor(red: 0xEF/255, green: 0x44/255, blue: 0x44/255, alpha: 1)
		: UIColor(red: 0xDC/255, green: 0x26/255, blue: 0x26/255, alpha: 1) })

	/// 紫（Apple ID 证书徽标）：#7C3AED / #A78BFA
	static let geekPurple = Color(UIColor { $0.userInterfaceStyle == .dark
		? UIColor(red: 0xA7/255, green: 0x8B/255, blue: 0xFA/255, alpha: 1)
		: UIColor(red: 0x7C/255, green: 0x3A/255, blue: 0xED/255, alpha: 1) })

	/// 页面底色 / 卡片背景：直接用系统语义色（规格书要求）
	static let geekPageBackground = Color(UIColor.systemGroupedBackground)
	static let geekCardBackground = Color(UIColor.secondarySystemGroupedBackground)
}

extension UIColor {
	static let geekPrimary = UIColor(Color.geekPrimary)
}

// MARK: - 全局 Toast（规格书 §5：操作成功顶部 Toast，2 秒自动消失）

/// 用法：GeekToast.show("已复制")
enum GeekToast {

	private static var _workItem: DispatchWorkItem?

	static func show(_ text: String, icon: String = "checkmark.circle.fill") {
		DispatchQueue.main.async { _present(text: text, icon: icon) }
	}

	private static func _present(text: String, icon: String) {
		guard let scene = UIApplication.shared.connectedScenes
			.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
			let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
		else { return }

		_workItem?.cancel()
		window.viewWithTag(96410)?.removeFromSuperview()

		let label = UILabel()
		label.font = .systemFont(ofSize: 14, weight: .medium)
		label.textColor = .white

		let attachment = NSTextAttachment()
		let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
		attachment.image = UIImage(systemName: icon, withConfiguration: config)?
			.withTintColor(.white, renderingMode: .alwaysOriginal)
		let full = NSMutableAttributedString(attachment: attachment)
		full.append(NSAttributedString(string: "  " + text))
		label.attributedText = full

		let container = UIView()
		container.backgroundColor = UIColor.black.withAlphaComponent(0.82)
		container.layer.cornerRadius = 999
		container.tag = 96410
		container.alpha = 0
		label.translatesAutoresizingMaskIntoConstraints = false
		container.addSubview(label)
		NSLayoutConstraint.activate([
			label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
			label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
			label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
			label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
		])

		container.translatesAutoresizingMaskIntoConstraints = false
		window.addSubview(container)
		NSLayoutConstraint.activate([
			container.centerXAnchor.constraint(equalTo: window.centerXAnchor),
			container.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 8),
		])

		UIView.animate(withDuration: 0.2) { container.alpha = 1 }
		let work = DispatchWorkItem {
			UIView.animate(withDuration: 0.2, animations: { container.alpha = 0 }) { _ in
				container.removeFromSuperview()
			}
		}
		_workItem = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
	}
}
