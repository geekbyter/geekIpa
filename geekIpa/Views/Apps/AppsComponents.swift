//
//  AppsComponents.swift
//  geekIpa
//
//  应用页共享组件：空状态（§5）、状态标签胶囊、目录大小异步文本、日期格式化。
//

import SwiftUI

// MARK: - 空状态（规格书 §5：SF Symbol + 一句说明 + 一个主操作按钮）

struct GeekEmptyStateView: View {
	let icon: String
	let title: String
	var message: String? = nil
	var buttonTitle: String? = nil
	var action: (() -> Void)? = nil
	
	var body: some View {
		VStack(spacing: 12) {
			Image(systemName: icon)
				.font(.system(size: 44, weight: .regular))
				.foregroundStyle(Color.geekPrimary)
				.padding(.bottom, 4)
			
			Text(title)
				.font(.headline)
				.multilineTextAlignment(.center)
			
			if let message {
				Text(message)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
			}
			
			if let buttonTitle, let action {
				Button(action: action) {
					Text(buttonTitle)
						.font(.subheadline.weight(.semibold))
						.foregroundStyle(.white)
						.padding(.horizontal, 20)
						.padding(.vertical, 10)
						.background(Capsule().fill(Color.geekPrimary))
				}
				.frame(minHeight: 44)
				.padding(.top, 4)
			}
		}
		.padding(24)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color.geekPageBackground)
	}
}

// MARK: - 状态标签胶囊（如「未签名」）

struct GeekTag: View {
	let text: String
	var color: Color = .geekWarning
	
	var body: some View {
		Text(text)
			.font(.caption2.weight(.semibold))
			.foregroundStyle(color)
			.padding(.horizontal, 8)
			.padding(.vertical, 3)
			.background(color.opacity(0.12))
			.clipShape(Capsule())
	}
}

// MARK: - App 目录大小（异步计算，避免阻塞列表渲染）

struct AppDirectorySizeText: View {
	let app: AppInfoPresentable
	@State private var _text: String = "…"
	
	var body: some View {
		Text(_text)
			.task(id: app.uuid) {
				await _load()
			}
	}
	
	private func _load() async {
		guard let directory = Storage.shared.getUuidDirectory(for: app) else {
			_text = "未知"
			return
		}
		let size = await Task.detached(priority: .utility) {
			geekDirectorySize(at: directory)
		}.value
		_text = ByteCountFormatter.string(fromByteCount: Int64(bitPattern: size), countStyle: .file)
	}
}

// MARK: - 工具函数

/// 目录递归大小（字节）
func geekDirectorySize(at url: URL) -> UInt64 {
	guard let enumerator = FileManager.default.enumerator(
		at: url,
		includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
		options: [.skipsHiddenFiles]
	) else { return 0 }
	
	var total: UInt64 = 0
	for case let fileURL as URL in enumerator {
		if
			let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
			let size = values.totalFileAllocatedSize
		{
			total += UInt64(size)
		}
	}
	return total
}

/// 列表用日期格式（如「2026/10/27 11:30」）
func geekFormatDate(_ date: Date?) -> String {
	guard let date else { return "未知时间" }
	return date.formatted(date: .abbreviated, time: .shortened)
}
