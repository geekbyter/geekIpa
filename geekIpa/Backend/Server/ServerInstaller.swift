//
//  Server.swift
//  geekIpa
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import SwiftUI

// MARK: - Class
class ServerInstaller: Identifiable, ObservableObject {
	let id = UUID()
	let port = Int.random(in: 4000...8000)
	private var _needsShutdown = false

	var packageUrl: URL?
	var app: AppInfoPresentable
	@ObservedObject var viewModel: InstallerStatusViewModel
	private var _server: LocalHTTPServer?

	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) {
		self.app = app
		self.viewModel = viewModel
		let logger = InstallLogger.shared
		logger.info("服务器", "正在初始化本地安装服务器…")

		_server = LocalHTTPServer(port: port)
		_configureRoutes()
		do {
			try _server?.start()
			_needsShutdown = true
			logger.success("服务器", "服务器已启动，端口 \(port)，地址 \(sni())，协议 http")
			logger.info("服务器", "清单地址: \(plistEndpoint.absoluteString)")
		} catch {
			// 端口占用等情况不再让 App 崩溃，只标记失败供 UI 提示
			logger.error("服务器", "服务器启动失败: \(error.localizedDescription)")
			_needsShutdown = false
			DispatchQueue.main.async {
				self.viewModel.status = .broken(error)
			}
		}
	}

	deinit {
		_shutdownServer()
	}

	private func _configureRoutes() {
		_server?.route { [weak self] req in
			guard let self else { return .status(500) }
			InstallLogger.shared.info("服务器", "收到请求: \(req.method) \(req.path)")

			switch req.path {
			case self.plistEndpoint.path:
				InstallLogger.shared.success("安装", "iOS 已获取安装清单（说明服务器可达）")
				self._updateStatus(.sendingManifest)
				return .data(self.installManifestData, contentType: "text/xml", status: 200, extraHeaders: [:])

			case self.displayImageSmallEndpoint.path:
				return .data(self.displayImageSmallData, contentType: "image/png", status: 200, extraHeaders: [:])

			case self.displayImageLargeEndpoint.path:
				return .data(self.displayImageLargeData, contentType: "image/png", status: 200, extraHeaders: [:])

			case self.payloadEndpoint.path:
				guard let packageUrl = self.packageUrl else {
					InstallLogger.shared.error("安装", "iOS 请求 IPA 包体但本地文件缺失")
					return .status(404)
				}
				InstallLogger.shared.success("安装", "iOS 开始下载 IPA 包体（\(packageUrl.lastPathComponent)）")
				self._updateStatus(.sendingPayload)

				DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
					InstallLogger.shared.success("安装", "IPA 包体开始传输，等待系统安装…")
					self._updateStatus(.installing)
				}
				return .file(packageUrl, contentType: "application/octet-stream", status: 200)

			case "/install":
				InstallLogger.shared.info("安装", "已打开安装引导页")
				return .html(self.html)

			default:
				return .status(404)
			}
		}
	}

	private func _shutdownServer() {
		guard _needsShutdown else { return }
		_needsShutdown = false
		_server?.stop()
	}

	private func _updateStatus(_ newStatus: InstallerStatusViewModel.InstallerStatus) {
		DispatchQueue.main.async {
			self.viewModel.status = newStatus
		}
	}

	/// 是否固定使用 127.0.0.1（设置入口已移除，默认使用局域网地址）
	func getIPFix() -> Bool {
		false
	}
}
