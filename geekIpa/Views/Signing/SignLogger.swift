//
//  SignLogger.swift
//  geekIpa
//
//  签名过程日志（规格书 §2.4 硬约束）：
//  · 纯内存环形缓冲，上限 2000 行，超出丢弃最早的行
//  · 不落盘、不写文件、不入数据库、不做任何持久化
//  · 页面退出（返回 / 取消 / 完成）即随视图释放，无历史日志
//  · 导出是用户显式行为：点击时才生成临时 .log，分享面板关闭后由调用方删除
//

import SwiftUI

final class SignLogger: ObservableObject {

	// MARK: - 级别

	enum Level: String {
		case info = "INFO"
		case warn = "WARN"
		case error = "ERROR"
		case success = "SUCCESS"

		/// 级别着色（规格书 §2.4）：INFO 次文字 / WARN 警示 / ERROR 危险 / SUCCESS 成功
		var color: Color {
			switch self {
			case .info: Color(uiColor: .secondaryLabel)
			case .warn: .geekWarning
			case .error: .geekDanger
			case .success: .geekSuccess
			}
		}
	}

	// MARK: - 日志行

	struct Entry: Identifiable, Equatable {
		let id: Int
		let timestamp: Date
		let level: Level
		let message: String
	}

	/// 环形缓冲上限（规格书 §2.4：最近 2000 行）
	static let capacity = 2000

	@Published private(set) var entries: [Entry] = []
	private var _nextID = 0

	private static let _timeFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm:ss"
		return formatter
	}()

	// MARK: - 写入（线程安全：统一切主线程，保证顺序与 SwiftUI 发布）

	func log(_ level: Level, _ message: String) {
		if Thread.isMainThread {
			_append(level, message)
		} else {
			DispatchQueue.main.async { self._append(level, message) }
		}
	}

	func info(_ message: String) { log(.info, message) }
	func warn(_ message: String) { log(.warn, message) }
	func error(_ message: String) { log(.error, message) }
	func success(_ message: String) { log(.success, message) }

	func clear() {
		if Thread.isMainThread {
			entries.removeAll()
		} else {
			DispatchQueue.main.async { self.entries.removeAll() }
		}
	}

	private func _append(_ level: Level, _ message: String) {
		entries.append(Entry(id: _nextID, timestamp: Date(), level: level, message: message))
		_nextID += 1
		if entries.count > Self.capacity {
			entries.removeFirst(entries.count - Self.capacity)
		}
	}

	// MARK: - 行渲染（[HH:mm:ss] 前缀）

	static func timeString(for date: Date) -> String {
		_timeFormatter.string(from: date)
	}

	static func renderedLine(_ entry: Entry) -> String {
		"[\(timeString(for: entry.timestamp))] [\(entry.level.rawValue)] \(entry.message)"
	}

	/// 全部日志文本（供「查看完整日志」与导出使用）
	func renderedText() -> String {
		entries.map(Self.renderedLine).joined(separator: "\n")
	}

	// MARK: - 导出（规格书 §2.4：点击时才生成临时 .log；分享完由调用方立即删除）

	func exportToTempFile() -> URL? {
		let stamp = Self._timeFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("geekIpa-签名日志-\(stamp)-\(UUID().uuidString.prefix(6)).log")

		do {
			try renderedText().write(to: url, atomically: true, encoding: .utf8)
			return url
		} catch {
			return nil
		}
	}
}
