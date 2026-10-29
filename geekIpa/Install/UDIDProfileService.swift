//
//  UDIDProfileService.swift
//  geekIpa
//
//  通过配置描述文件获取设备信息：
//  1. App 内起一个极小的本机 HTTP 服务（127.0.0.1:随机端口）
//  2. 打开 Safari 下载并安装描述文件，安装时系统会把设备属性 POST 回本机
//  3. 解析回传的 UDID / 序列号 / 型号 / 系统版本并保存
//
//  注意：不同系统版本回传的封装不同（可能是裸 plist，也可能是 CMS/PKCS#7 签名包），
//  解析做了三级兜底，并把原始回传写进诊断日志便于排查。
//

import Foundation
import UIKit
import SwiftUI

final class UDIDProfileService: ObservableObject {

	static let shared = UDIDProfileService()

	@Published private(set) var isRunning = false
	@Published private(set) var receivedUDID: String?
	@Published private(set) var receivedSerial: String?
	@Published private(set) var receivedProduct: String?
	@Published private(set) var receivedVersion: String?
	@Published private(set) var lastCallbackHadNoUDID = false

	private var _server: LocalHTTPServer?
	private(set) var port: Int = 0

	private init() {}

	// MARK: - 启停

	/// 打开 Safari 后 App 立即进后台，需要后台任务换取存活时间（收到回调或 stop 时结束）
	private var _backgroundTask: UIBackgroundTaskIdentifier = .invalid

	func start() async throws -> URL {
		stop()

		let candidatePort = Int.random(in: 4000...8000)
		let server = LocalHTTPServer(port: candidatePort)
		_registerRoutes(on: server)
		try server.start()

		// 回环自检：NWListener 的绑定失败是异步上报的，start() 可能“假成功”。
		// 这里直接拉一次 / ，拿到任意 HTTP 响应才算真正就绪。
		guard await Self._probe(port: candidatePort, timeout: 2.0) else {
			server.stop()
			throw URLError(.cannotConnectToHost)
		}

		_server = server
		port = candidatePort
		isRunning = true

		guard let url = URL(string: "http://127.0.0.1:\(candidatePort)/") else {
			throw URLError(.badURL)
		}
		return url
	}

	func stop() {
		_endBackgroundTask()
		guard let server = _server else { return }
		_server = nil
		isRunning = false
		server.stop()
	}

	// MARK: - 后台任务

	func beginBackgroundTask() {
		guard _backgroundTask == .invalid else { return }
		_backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "geekIpa.udid-profile") {
			self._endBackgroundTask()
		}
	}

	private func _endBackgroundTask() {
		if _backgroundTask != .invalid {
			UIApplication.shared.endBackgroundTask(_backgroundTask)
			_backgroundTask = .invalid
		}
	}

	// MARK: - 回环自检

	private static func _probe(port: Int, timeout: TimeInterval) async -> Bool {
		guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return false }
		var request = URLRequest(url: url)
		request.timeoutInterval = timeout
		do {
			let (_, response) = try await URLSession.shared.data(for: request)
			return (response as? HTTPURLResponse) != nil
		} catch {
			return false
		}
	}

	// MARK: - 路由

	private func _registerRoutes(on server: LocalHTTPServer) {
		server.route { [weak self] req in
			guard let self else { return .status(404) }

			switch req.path {
			case "/":
				return .html(self._landingHTML())

			case "/udid.mobileconfig":
				return .data(
					Data(self._profileXML().utf8),
					contentType: "application/x-apple-aspen-config",
					status: 200,
					extraHeaders: ["Content-Disposition": "attachment; filename=\"geekIpa-udid.mobileconfig\""]
				)

			case "/udid-callback":
				let body = String(data: req.body, encoding: .utf8) ?? ""
				self._handleCallback(body)
			self._endBackgroundTask()
				return .html(self._doneHTML())

			default:
				return .status(404)
			}
		}
	}

	// MARK: - 回传解析

	private func _handleCallback(_ body: String) {
		InstallLogger.shared.info("UDID", "收到描述文件回传（\(body.count) 字节）")

		var dict: [String: Any]?

		// ① 裸 plist
		if let data = body.data(using: .utf8),
		   let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
			dict = obj as? [String: Any]
		}

		// ② CMS/PKCS#7 签名包中的 plist
		if dict == nil,
		   let a = body.range(of: "<?xml"),
		   let b = body.range(of: "</plist>") {
			let inner = String(body[a.lowerBound..<b.upperBound])
			if let data = inner.data(using: .utf8),
			   let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
				dict = obj as? [String: Any]
			}
		}

		var udid = dict?["UDID"] as? String
		var serial = dict?["SERIAL"] as? String
		var product = dict?["PRODUCT"] as? String
		var version = dict?["VERSION"] as? String

		// ③ 正则兜底
		if udid == nil { udid = Self._value(in: body, key: "UDID") }
		if serial == nil { serial = Self._value(in: body, key: "SERIAL") }
		if product == nil { product = Self._value(in: body, key: "PRODUCT") }
		if version == nil { version = Self._value(in: body, key: "VERSION") }

		InstallLogger.shared.info("UDID", "解析结果 UDID=\(udid ?? "无") SERIAL=\(serial ?? "无")")

		DispatchQueue.main.async {
			self.receivedSerial = serial
			self.receivedProduct = product
			self.receivedVersion = version
			self.lastCallbackHadNoUDID = (udid == nil)

			if let udid, DeviceIdentity.save(udid) {
				self.receivedUDID = DeviceIdentity.udid
				InstallLogger.shared.success("UDID", "已获取并保存 UDID: \(udid)")
			} else {
				self.receivedUDID = nil
				InstallLogger.shared.warning("UDID", "回传中未找到 UDID，可在面板内手动填写")
			}
		}
	}

	private static func _value(in body: String, key: String) -> String? {
		let pattern = "<key>\(key)</key>\\s*<string>([^<]+)</string>"
		guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
		let range = NSRange(body.startIndex..<body.endIndex, in: body)
		guard let m = re.firstMatch(in: body, options: [], range: range),
		      m.numberOfRanges > 1,
		      let vr = Range(m.range(at: 1), in: body) else { return nil }
		let v = String(body[vr]).trimmingCharacters(in: .whitespacesAndNewlines)
		return v.isEmpty ? nil : v
	}

	// MARK: - 页面 / 描述文件

	private func _landingHTML() -> String {
		"""
		<!DOCTYPE html><html lang="zh-CN"><head>
		<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
		<title>获取设备 UDID</title>
		<style>
		body{font:16px/1.6 -apple-system,Helvetica;margin:0;padding:24px;background:#f2f2f7;color:#111}
		h1{font-size:20px;margin:0 0 12px} p{color:#3c3c43} ol{color:#3c3c43;padding-left:20px}
		a.btn{display:block;text-align:center;background:#2563eb;color:#fff;text-decoration:none;
		padding:14px;border-radius:12px;font-weight:600;margin:20px 0}
		</style></head><body>
		<h1>获取设备 UDID</h1>
		<a class="btn" href="/udid.mobileconfig">① 下载描述文件</a>
		<ol>
		<li>点击上面的按钮并允许下载</li>
		<li>打开「设置」→「已下载描述文件」→ 安装</li>
		<li>完成后回到 geekIpa，UDID 会自动填入</li>
		</ol>
		</body></html>
		"""
	}

	private func _doneHTML() -> String {
		"""
		<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
		<meta name="viewport" content="width=device-width, initial-scale=1"><title>已完成</title>
		<style>body{font:16px/1.6 -apple-system;padding:24px;text-align:center;background:#f2f2f7}
		h1{font-size:20px;margin:36px 0 12px;color:#16a34a}</style></head>
		<body><h1>已获取设备信息</h1><p>请关闭本页并返回 geekIpa。</p></body></html>
		"""
	}

	private func _profileXML() -> String {
		let u1 = UUID().uuidString
		let u2 = UUID().uuidString
		return """
		<?xml version="1.0" encoding="UTF-8"?>
		<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
		<plist version="1.0">
		<dict>
			<key>PayloadContent</key>
			<dict>
				<key>DeviceAttributes</key>
				<array>
					<string>UDID</string>
					<string>IMEI</string>
					<string>ICCID</string>
					<string>MEID</string>
					<string>SERIAL</string>
					<string>PRODUCT</string>
					<string>VERSION</string>
				</array>
				<key>PayloadDescription</key>
				<string>读取设备信息用于向 Apple 注册签名设备</string>
				<key>PayloadDisplayName</key>
				<string>获取设备 UDID</string>
				<key>PayloadIdentifier</key>
				<string>com.geekipa.ios.udid.service</string>
				<key>PayloadOrganization</key>
				<string>geekIpa</string>
				<key>PayloadType</key>
				<string>Profile Service</string>
				<key>PayloadUUID</key>
				<string>\(u1)</string>
				<key>PayloadVersion</key>
				<integer>1</integer>
				<key>URL</key>
				<string>http://127.0.0.1:\(port)/udid-callback</string>
			</dict>
			<key>PayloadDescription</key>
			<string>安装后会把本机设备信息发送给 geekIpa（仅本机）</string>
			<key>PayloadDisplayName</key>
			<string>获取设备 UDID</string>
			<key>PayloadIdentifier</key>
			<string>com.geekipa.ios.udid</string>
			<key>PayloadOrganization</key>
			<string>geekIpa</string>
			<key>PayloadRemovalDisallowed</key>
			<false/>
			<key>PayloadType</key>
			<string>Configuration</string>
			<key>PayloadUUID</key>
			<string>\(u2)</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
		</dict>
		</plist>
		"""
	}
}
