//
//  WorkCache.swift
//  geekIpa
//
//  启动时清理临时目录（签名/安装产生的中间文件）。
//

import Foundation

enum WorkCache {
	static func clearTemporary() {
		let fileManager = FileManager.default
		let tmp = fileManager.temporaryDirectory
		if let files = try? fileManager.contentsOfDirectory(atPath: tmp.path()) {
			for file in files {
				try? fileManager.removeItem(at: tmp.appendingPathComponent(file))
			}
		}
	}
}
