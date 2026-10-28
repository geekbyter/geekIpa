//
//  AnisetteService.swift
//  geekIpa
//
//  职责：从公共 Anisette 服务器按顺序拉取 Anisette 数据（GSA 认证所需的设备指纹），
//  解析为 AltSign 的 ALTAnisetteData。
//  - 服务器列表按序尝试，单台 5 秒超时，失败自动切换下一台
//  - 成功结果内存缓存 60 秒（oneTimePassword 时效很短，不宜长缓存）
//  - 并发请求合并为同一个任务，避免重复拉取
//

import Foundation
import AltSign

/// Anisette 拉取错误（描述均为简体中文，可直接展示给用户）
enum AnisetteServiceError: LocalizedError {
	/// 所有服务器都无法连接或都返回了无效数据
	case allServersFailed
	/// 某台服务器返回了无效数据
	case invalidResponse(String)

	var errorDescription: String? {
		switch self {
		case .allServersFailed:
			return "所有 Anisette 服务器均无法连接，请检查网络后重试"
		case .invalidResponse(let server):
			return "Anisette 服务器（\(server)）返回了无效数据"
		}
	}
}

actor AnisetteService {
	static let shared = AnisetteService()

	/// 公共 Anisette 服务器列表（按优先级排序，逐台尝试）
	static let serverURLs = [
		"https://ani.sidestore.io",
		"https://anisette-v3.fly.dev"
	]

	private let _timeout: TimeInterval = 5
	private let _cacheLifetime: TimeInterval = 60

	private var _cache: (data: ALTAnisetteData, fetchedAt: Date)?
	private var _inflightTask: Task<ALTAnisetteData, Error>?

	private init() {}

	/// 获取 Anisette 数据（60 秒内复用内存缓存）
	func fetchAnisetteData() async throws -> ALTAnisetteData {
		if let cache = _cache,
		   Date().timeIntervalSince(cache.fetchedAt) < _cacheLifetime {
			return cache.data
		}

		if let task = _inflightTask {
			return try await task.value
		}

		let task = Task<ALTAnisetteData, Error> {
			try await self._fetchFromServerList()
		}
		_inflightTask = task

		do {
			let data = try await task.value
			_cache = (data, Date())
			_inflightTask = nil
			return data
		} catch {
			_inflightTask = nil
			throw error
		}
	}


	// MARK: - 内部实现

	private func _fetchFromServerList() async throws -> ALTAnisetteData {
		var lastError: Error = AnisetteServiceError.allServersFailed

		for server in Self.serverURLs {
			do {
				return try await _fetch(from: server)
			} catch {
				NSLog("[AppleID] Anisette 服务器 %@ 拉取失败：%@", server, error.localizedDescription)
				lastError = error
				continue
			}
		}

		throw lastError
	}

	private func _fetch(from server: String) async throws -> ALTAnisetteData {
		guard let url = URL(string: server) else {
			throw AnisetteServiceError.invalidResponse(server)
		}

		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		request.timeoutInterval = _timeout
		request.setValue("application/json", forHTTPHeaderField: "Accept")

		let session = URLSession(configuration: .ephemeral)
		let (data, response) = try await session.data(for: request)

		if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
			throw AnisetteServiceError.invalidResponse(server)
		}

		guard
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let json = Self._mapServerResponse(object),
			let anisette = ALTAnisetteData(json: json)
		else {
			throw AnisetteServiceError.invalidResponse(server)
		}

		return anisette
	}

	/// 将服务器的 HTTP 头风格字段映射为 ALTAnisetteData(json:) 需要的键。
	/// 注意：ALTAnisetteData(json:) 是 failable 构造器，缺任一键都会返回 nil。
	private static func _mapServerResponse(_ object: [String: Any]) -> [String: String]? {
		let keyMap: [String: String] = [
			"machineID": "X-Apple-I-MD-M",
			"oneTimePassword": "X-Apple-I-MD",
			"localUserID": "X-Apple-I-MD-LU",
			"routingInfo": "X-Apple-I-MD-RINFO",
			"deviceUniqueIdentifier": "X-Mme-Device-Id",
			"deviceSerialNumber": "X-Apple-I-SRL-NO",
			"deviceDescription": "X-MMe-Client-Info",
			"date": "X-Apple-I-Client-Time",
			"locale": "X-Apple-Locale",
			"timeZone": "X-Apple-I-TimeZone"
		]

		var mapped: [String: String] = [:]
		for (jsonKey, serverKey) in keyMap {
			guard let value = object[serverKey] else { return nil }
			mapped[jsonKey] = String(describing: value)
		}
		return mapped
	}
}
