//
//  InstallLogger.swift
//  geekIpa
//
//  职责：安装/签名全流程的统一日志中心。
//  - 内存环形缓冲（默认 500 条）供 UI 实时滚屏展示
//  - 同步落盘 Documents/logs/install-日期.log，可在设置页导出
//

import Foundation
import Combine
import UIKit

/// 日志级别
enum InstallLogLevel: Int, Comparable {
	case debug = 0
	case info = 1
	case success = 2
	case warning = 3
	case error = 4

	static func < (lhs: InstallLogLevel, rhs: InstallLogLevel) -> Bool {
		lhs.rawValue < rhs.rawValue
	}

	var emoji: String {
		switch self {
		case .debug: return "🔍"
		case .info: return "ℹ️"
		case .success: return "✅"
		case .warning: return "⚠️"
		case .error: return "❌"
		}
	}
}

struct InstallLogEntry: Identifiable {
	let id = UUID()
	let time: Date
	let level: InstallLogLevel
	let step: String
	let message: String

	var line: String {
		let fmt = DateFormatter()
		fmt.dateFormat = "HH:mm:ss.SSS"
		return "[\(fmt.string(from: time))] \(level.emoji) [\(step)] \(message)"
	}
}

/// 全局安装日志中心（主线程发布，写文件在后台串行队列）
final class InstallLogger: ObservableObject {
	static let shared = InstallLogger()

	@Published private(set) var entries: [InstallLogEntry] = []

	/// 内存缓冲上限
	var capacity = 500

	private let _fileQueue = DispatchQueue(label: "com.geekipa.installlogger.file", qos: .utility)
	private let _fileManager = FileManager.default

	private init() {}

	// MARK: - 记录

	func log(_ step: String, _ level: InstallLogLevel, _ message: String) {
		let entry = InstallLogEntry(time: Date(), level: level, step: step, message: message)
		DispatchQueue.main.async {
			self.entries.append(entry)
			if self.entries.count > self.capacity {
				self.entries.removeFirst(self.entries.count - self.capacity)
			}
		}
		_writeToFile(entry)
	}

	func info(_ step: String, _ message: String) { log(step, .info, message) }
	func success(_ step: String, _ message: String) { log(step, .success, message) }
	func warning(_ step: String, _ message: String) { log(step, .warning, message) }
	func error(_ step: String, _ message: String) { log(step, .error, message) }

	/// 清空内存日志（开始新一轮安装前调用）
	func clear() {
		DispatchQueue.main.async { self.entries.removeAll() }
	}

	// MARK: - 落盘

	private var _logFileURL: URL {
		let fmt = DateFormatter()
		fmt.dateFormat = "yyyyMMdd"
		let dir = URL.documentsDirectory.appendingPathComponent("logs", isDirectory: true)
		return dir.appendingPathComponent("install-\(fmt.string(from: Date())).log")
	}

	private func _writeToFile(_ entry: InstallLogEntry) {
		_fileQueue.async {
			let url = self._logFileURL
			try? self._fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			let line = entry.line + "\n"
			guard let data = line.data(using: .utf8) else { return }
			if self._fileManager.fileExists(atPath: url.path) {
				if let handle = try? FileHandle(forWritingTo: url) {
					defer { try? handle.close() }
					try? handle.seekToEnd()
					try? handle.write(contentsOf: data)
				}
			} else {
				try? data.write(to: url, options: .atomic)
			}
		}
	}

	/// 导出今日日志文件 URL（供分享）
	func todayLogFile() -> URL? {
		let url = _logFileURL
		return _fileManager.fileExists(atPath: url.path) ? url : nil
	}

	/// 全部日志文件（按名称倒序）
	func allLogFiles() -> [URL] {
		let dir = URL.documentsDirectory.appendingPathComponent("logs", isDirectory: true)
		let files = (try? _fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
		return files.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
	}
}
