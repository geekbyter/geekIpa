//
//  Server.swift
//  geekIpa
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import Vapor
import NIOSSL
import NIOTLS
import SwiftUI
import IDeviceSwift

// MARK: - Class
class ServerInstaller: Identifiable, ObservableObject {
	let id = UUID()
	let port = Int.random(in: 4000...8000)
	private var _needsShutdown = false
	
	var packageUrl: URL?
	var app: AppInfoPresentable
	@ObservedObject var viewModel: InstallerStatusViewModel
	private var _server: Application?

	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) throws {
		self.app = app
		self.viewModel = viewModel
		let logger = InstallLogger.shared
		logger.info("服务器", "正在初始化本地安装服务器…")
		try _setup()
		try _configureRoutes()
		try _server?.server.start()
		_needsShutdown = true
		logger.success("服务器", "服务器已启动，端口 \(port)，地址 \(sni())，协议 \(getServerMethod() == 1 ? "http" : "https")")
		logger.info("服务器", "清单地址: \(plistEndpoint.absoluteString)")
		if getServerMethod() != 1 {
			let hasCert = Self.getUrl("server", ext: "crt") != nil && Self.getUrl("server", ext: "pem") != nil
			if hasCert {
				logger.success("服务器", "TLS 证书文件存在")
			} else {
				logger.error("服务器", "缺少 TLS 证书（server.crt/server.pem），iOS 将无法通过 https 拉取清单——请到 设置→安装方式 检查或重新构建")
			}
		}
	}
	
	deinit {
		_shutdownServer()
	}
	
	private func _setup() throws {
		self._server = try? setupApp(port: port)
	}
		
	private func _configureRoutes() throws {
		_server?.get("*") { [weak self] req in
			guard let self else { return Response(status: .badGateway) }
			InstallLogger.shared.info("服务器", "收到请求: \(req.url.path)")
			switch req.url.path {
			case plistEndpoint.path:
				InstallLogger.shared.success("安装", "iOS 已获取安装清单（说明服务器可达、TLS 正常）")
				self._updateStatus(.sendingManifest)
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "text/xml",
				], body: .init(data: installManifestData))
			case displayImageSmallEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageSmallData))
			case displayImageLargeEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageLargeData))
			case payloadEndpoint.path:
				guard let packageUrl = packageUrl else {
					InstallLogger.shared.error("安装", "iOS 请求 IPA 包体但本地文件缺失")
					return Response(status: .notFound)
				}

				InstallLogger.shared.success("安装", "iOS 开始下载 IPA 包体（\(packageUrl.lastPathComponent)）")
				self._updateStatus(.sendingPayload)

				return req.fileio.streamFile(
					at: packageUrl.path
				) { result in
					switch result {
					case .success:
						InstallLogger.shared.success("安装", "IPA 包体传输完成，等待系统安装…")
						self._updateStatus(.installing)
					case .failure(let error):
						InstallLogger.shared.error("安装", "IPA 包体传输失败: \(error.localizedDescription)")
						self._updateStatus(.broken(error))
					}

				}
			case "/install":
				var headers = HTTPHeaders()
				headers.add(name: .contentType, value: "text/html")
				return Response(status: .ok, headers: headers, body: .init(string: self.html))
			default:
				return Response(status: .notFound)
			}
		}
	}
	
	private func _shutdownServer() {
		guard _needsShutdown else { return }
		
		_needsShutdown = false
		_server?.server.shutdown()
		_server?.shutdown()
	}
	
	private func _updateStatus(_ newStatus: InstallerStatusViewModel.InstallerStatus) {
		DispatchQueue.main.async {
			self.viewModel.status = newStatus
		}
	}
		
	/// 1 = 本机 HTTP + 局域网 IP（默认，不依赖外部证书）
	/// 0 = 本机 HTTPS（需 server.crt/pem）
	func getServerMethod() -> Int {
		if let stored = UserDefaults.standard.object(forKey: "geekIpa.serverMethod") as? Int {
			return stored
		}
		return 1
	}
	
	/// 是否固定使用 127.0.0.1（设置入口已移除，默认使用局域网地址）
	func getIPFix() -> Bool {
		false
	}
}
