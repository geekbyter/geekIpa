//
//  InstallLogView.swift
//  geekIpa
//
//  职责：固定尺寸的滚屏日志面板。
//  - 固定高度（默认 220pt），内部 ScrollView 自动滚到最新一条
//  - 按级别着色，等宽字体，支持复制单行 / 导出全部
//

import SwiftUI
import UIKit

struct InstallLogView: View {
	@ObservedObject private var _logger = InstallLogger.shared

	/// 面板固定高度（用户要求：日志过多时固定尺寸滚屏）
	var height: CGFloat = 220

	@State private var _autoScroll = true

	var body: some View {
		VStack(spacing: 0) {
			_header()
			_logArea()
		}
		.frame(height: height)
		.background(Color(UIColor.secondarySystemBackground))
		.cornerRadius(12)
	}

	// MARK: - 头部工具条

	private func _header() -> some View {
		HStack(spacing: 12) {
			Text("安装日志")
				.font(.caption.weight(.semibold))
				.foregroundColor(.secondary)

			Text("\(_logger.entries.count) 条")
				.font(.caption2)
				.foregroundColor(.secondary)

			Spacer()

			Toggle("", isOn: $_autoScroll)
				.labelsHidden()
				.scaleEffect(0.6)
				.frame(width: 40)
			Text("滚屏")
				.font(.caption2)
				.foregroundColor(.secondary)

			Button {
				UIPasteboard.general.string = _logger.entries.map(\.line).joined(separator: "\n")
			} label: {
				Image(systemName: "doc.on.doc")
					.font(.caption)
			}
			.buttonStyle(.borderless)

			if let file = _logger.todayLogFile() {
				ShareLink(item: file) {
					Image(systemName: "square.and.arrow.up")
						.font(.caption)
				}
			}
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 6)
	}

	// MARK: - 日志区

	private func _logArea() -> some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 2) {
					ForEach(_logger.entries) { entry in
						Text(entry.line)
							.font(.system(size: 10, design: .monospaced))
							.foregroundColor(_color(for: entry.level))
							.frame(maxWidth: .infinity, alignment: .leading)
							.textSelection(.enabled)
							.id(entry.id)
					}
					// 底部锚点
					Color.clear.frame(height: 1).id("bottom")
				}
				.padding(.horizontal, 8)
				.padding(.bottom, 6)
			}
			.background(Color(UIColor.systemBackground))
			.cornerRadius(8)
			.padding(.horizontal, 8)
			.padding(.bottom, 8)
			.onChange(of: _logger.entries.count) { _ in
				guard _autoScroll else { return }
				withAnimation(.linear(duration: 0.1)) {
					proxy.scrollTo("bottom", anchor: .bottom)
				}
			}
		}
	}

	private func _color(for level: InstallLogLevel) -> Color {
		switch level {
		case .debug: return .secondary
		case .info: return .primary
		case .success: return .green
		case .warning: return .orange
		case .error: return .red
		}
	}
}

// MARK: - 设置页用的全屏日志页

struct InstallLogFullView: View {
	@ObservedObject private var _logger = InstallLogger.shared

	var body: some View {
		VStack(spacing: 12) {
			InstallLogView(height: 420)
				.padding(.horizontal)

			Section {
				ForEach(_logger.allLogFiles(), id: \.self) { file in
					ShareLink(item: file) {
						Label(file.lastPathComponent, systemImage: "doc.text")
					}
				}
			}
			.padding(.horizontal)

			Button(role: .destructive) {
				_logger.clear()
			} label: {
				Text("清空当前日志")
					.frame(maxWidth: .infinity)
			}
			.padding(.horizontal)

			Spacer()
		}
		.padding(.top)
		.navigationTitle("诊断日志")
	}
}
