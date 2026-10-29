//
//  LocalHTTPServer.swift
//  geekIpa
//
//  极简本机 HTTP/1.1 服务（Network.framework 实现）。
//  用途：itms-services 安装清单/包体分发、UDID 描述文件下发与回调接收。
//
//  设计取舍：只支持本机安装场景所需的最小集合 ——
//  · GET / HEAD / POST
//  · 固定 Content-Length 响应（不支持 chunked、不支持 Range）
//  · 一次请求一个响应后关闭连接（Connection: close），足够 iOS 安装流程使用
//  这样可以完全不依赖 Vapor / NIO / NIOSSL。
//

import Foundation
import Network
import OSLog

/// 极简 HTTP 服务
final class LocalHTTPServer {

	struct Request {
		let method: String
		let path: String
		let headers: [String: String]
		let body: Data

		/// 取请求头（大小写不敏感）
		func value(forHeader name: String) -> String? {
			headers[name.lowercased()]
		}
	}

	/// 响应
	///
	/// 注意：
	/// · Swift 枚举 case 不支持关联值默认参数，因此关联值全部显式声明；
	/// · 也不能额外定义同名静态方法（默认值不参与签名，会构成 invalid redeclaration），
	///   所以只保留 `html` 这个不同名的便利构造。
	enum Response {
		/// 直接返回内存数据
		case data(Data, contentType: String, status: Int, extraHeaders: [String: String])
		/// 流式返回文件（避免整包读入内存）
		case file(URL, contentType: String, status: Int)
		/// 仅状态码
		case status(Int)

		/// HTML 便利构造
		static func html(_ string: String, status: Int = 200) -> Response {
			.data(Data(string.utf8),
				  contentType: "text/html; charset=utf-8",
				  status: status,
				  extraHeaders: [:])
		}
	}

	private let _port: UInt16
	private var _listener: NWListener?
	private let _queue = DispatchQueue(label: "geekipa.localhttp")
	private var _handler: ((Request) -> Response)?

	/// 正在监听时为 true
	private(set) var isRunning = false

	init(port: Int) {
		self._port = UInt16(clamping: port)
	}

	/// 注册统一路由（单入口，按 path 分发）
	func route(_ handler: @escaping (Request) -> Response) {
		_handler = handler
	}

	func start() throws {
		guard _listener == nil else { return }
		guard let nwPort = NWEndpoint.Port(rawValue: _port) else {
			throw NSError(domain: "geekIpa.LocalHTTPServer", code: 1,
						  userInfo: [NSLocalizedDescriptionKey: "无效端口 \(_port)"])
		}

		let tcpOptions = NWProtocolTCP.Options()
		tcpOptions.noDelay = true
		let params = NWParameters(tls: nil, tcp: tcpOptions)
		params.allowLocalEndpointReuse = true

		let listener = try NWListener(using: params, on: nwPort)
		listener.newConnectionHandler = { [weak self] connection in
			self?._handle(connection)
		}
		listener.stateUpdateHandler = { state in
			if case let .failed(error) = state {
				Logger.misc.error("LocalHTTPServer 监听失败: \(String(describing: error))")
			}
		}
		listener.start(queue: _queue)
		_listener = listener
		isRunning = true
	}

	func stop() {
		_listener?.cancel()
		_listener = nil
		isRunning = false
	}

	// MARK: - 连接处理

	private func _handle(_ connection: NWConnection) {
		connection.start(queue: _queue)
		_receive(connection, buffer: Data())
	}

	/// 头部最大长度（防御异常请求占满内存）
	private static let _maxHeaderBytes = 64 * 1024

	private func _receive(_ connection: NWConnection, buffer: Data) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
			guard let self else { return }

			if let error {
				Logger.misc.error("LocalHTTPServer 读取失败: \(String(describing: error))")
				connection.cancel()
				return
			}

			var data = buffer
			if let chunk { data.append(chunk) }

			// 头部是否完整
			guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
				// 对端已关闭或头部异常膨胀：直接结束，避免在已完成连接上反复递归
				if isComplete || data.count > Self._maxHeaderBytes {
					Logger.misc.error("LocalHTTPServer 请求头部不完整或超长，关闭连接")
					connection.cancel()
				} else {
					self._receive(connection, buffer: data)
				}
				return
			}

			let headerData = data[..<headerRange.lowerBound]
			guard let headerText = String(data: headerData, encoding: .utf8) else {
				connection.cancel()
				return
			}

			let parsed = Self._parse(headerText)
			let bodyStart = headerRange.upperBound
			let contentLength = Int(parsed.headers["content-length"] ?? "0") ?? 0
			var body = Data(data[bodyStart...])

			if body.count < contentLength {
				// body 尚未收齐：对端已结束则放弃，否则继续读（避免在完成态无限递归）
				if isComplete {
					Logger.misc.error("LocalHTTPServer body 未收齐（期望 \(contentLength) 字节，实际 \(body.count)），关闭连接")
					connection.cancel()
				} else {
					self._receive(connection, buffer: data)
				}
				return
			}
			if contentLength > 0 {
				body = body.prefix(contentLength)
			} else {
				body = Data()
			}

			let request = Request(
				method: parsed.method,
				path: parsed.path,
				headers: parsed.headers,
				body: body
			)

			let response = self._handler?(request) ?? .status(404)
			self._send(response, for: request, on: connection)
		}
	}

	private static func _parse(_ header: String) -> (method: String, path: String, headers: [String: String]) {
		let lines = header.components(separatedBy: "\r\n")
		var method = "GET"
		var path = "/"
		if let first = lines.first {
			let parts = first.split(separator: " ")
			if parts.count >= 2 {
				method = String(parts[0]).uppercased()
				path = String(parts[1])
			}
		}
		// 去掉 query
		if let q = path.firstIndex(of: "?") {
			path = String(path[..<q])
		}

		var headers: [String: String] = [:]
		for line in lines.dropFirst() {
			guard let colon = line.firstIndex(of: ":") else { continue }
			let key = String(line[..<colon])
				.trimmingCharacters(in: .whitespaces)
				.lowercased()
			let value = String(line[line.index(after: colon)...])
				.trimmingCharacters(in: .whitespaces)
			headers[key] = value
		}
		return (method, path, headers)
	}

	// MARK: - 响应

	private func _send(_ response: Response, for request: Request, on connection: NWConnection) {
		switch response {
		case let .data(body, contentType, status, extra):
			var headers = extra
			headers["Content-Type"] = contentType
			let head = Self._head(status: status, length: body.count, extra: headers)
			var payload = Data(head.utf8)
			if request.method != "HEAD" { payload.append(body) }
			connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })

		case let .file(url, contentType, status):
			guard let handle = try? FileHandle(forReadingFrom: url) else {
				let head = Self._head(status: 404, length: 0, extra: [:])
				connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
				return
			}
			let size = (try? handle.seekToEnd()) ?? 0
			try? handle.seek(toOffset: 0)
			let head = Self._head(status: status, length: Int(size), extra: ["Content-Type": contentType])

			// HEAD 请求只回头部
			if request.method == "HEAD" {
				try? handle.close()
				connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
				return
			}

			connection.send(content: Data(head.utf8), completion: .contentProcessed { error in
				guard error == nil else { connection.cancel(); return }
				Self._streamFile(handle, on: connection)
			})

		case let .status(code):
			let head = Self._head(status: code, length: 0, extra: [:])
			connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
		}
	}

	private static func _head(status: Int, length: Int, extra: [String: String]) -> String {
		var lines = ["HTTP/1.1 \(status) \(_reason(status))"]
		lines.append("Content-Length: \(length)")
		for (k, v) in extra {
			lines.append("\(k): \(v)")
		}
		lines.append("Connection: close")
		lines.append("")
		lines.append("")
		return lines.joined(separator: "\r\n")
	}

	private static func _reason(_ status: Int) -> String {
		switch status {
		case 200: return "OK"
		case 206: return "Partial Content"
		case 404: return "Not Found"
		case 500: return "Internal Server Error"
		default: return "OK"
		}
	}

	private static func _streamFile(_ handle: FileHandle, on connection: NWConnection) {
		let chunk = handle.readData(ofLength: 512 * 1024)
		if chunk.isEmpty {
			try? handle.close()
			connection.cancel()
			return
		}
		connection.send(content: chunk, completion: .contentProcessed { error in
			guard error == nil else {
				try? handle.close()
				connection.cancel()
				return
			}
			_streamFile(handle, on: connection)
		})
	}
}
