//
//  Server+Compute.swift
//  geekIpa
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import UIKit.UIGraphicsImageRenderer

extension ServerInstaller {
	var plistEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = "http"
		comps.host = sni()
		comps.path = "/\(id).plist"
		comps.port = port
		return comps.url!
	}

	var payloadEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = "http"
		comps.host = sni()
		comps.path = "/\(id).ipa"
		comps.port = port
		return comps.url!
	}
	
	var pageEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = "http"
		comps.host = sni()
		comps.path = "/install"
		comps.port = port
		return comps.url!
	}
	
	var iTunesLink: String {
		_iTunesLink(with: plistEndpoint.absoluteString)
	}
	
	private func _iTunesLink(with url: String) -> String {
		return "itms-services://?action=download-manifest&url=\(url)"
	}

	var displayImageSmallEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = "http"
		comps.host = sni()
		comps.path = "/app57x57.png"
		comps.port = port
		return comps.url!
	}

	var displayImageLargeEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = "http"
		comps.host = sni()
		comps.path = "/app512x512.png"
		comps.port = port
		return comps.url!
	}
	
	var displayImageSmallData: Data {
		_createIcon(57)
	}
	
	var displayImageLargeData: Data {
		_createIcon(512)
	}
	
	private func _createIcon(_ r: CGFloat) -> Data {
		let renderer = UIGraphicsImageRenderer(size: .init(width: r, height: r))
		let image = renderer.image { ctx in
			UIColor.tintColor.setFill()
			ctx.fill(.init(x: 0, y: 0, width: r, height: r))
		}
		return image.pngData() ?? Data()
	}

	var html: String {
		"""
		<html style="background-color: black;">
		<script type="text/javascript">window.location="\(iTunesLink)"</script>
		</html>
		"""
	}

	var installManifest: [String: Any] {
		// 清单元数据必须以实际签出的 IPA 为准：签名页可能修改 Bundle ID / 版本 / 名称，
		// 若仍使用导入 IPA 的旧值，iOS 会按错误标识安装，安装后也无法正确打开。
		let bundle = Storage.shared.getAppDirectory(for: app).flatMap(Bundle.init(url:))
		let identifier = bundle?.bundleIdentifier ?? app.identifier ?? "com.geekipa.unknown"
		let version = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String ?? app.version ?? "1.0"
		let name = bundle?.infoDictionary?["CFBundleDisplayName"] as? String
			?? bundle?.infoDictionary?["CFBundleName"] as? String
			?? app.name ?? "App"

		return [
		"items": [[
			"assets": [
				[
					"kind": "software-package",
					"url": payloadEndpoint.absoluteString,
				],
				[
					"kind": "display-image",
					"url": displayImageSmallEndpoint.absoluteString,
				],
				[
					"kind": "full-size-image",
					"url": displayImageLargeEndpoint.absoluteString,
				],
			],
			"metadata": [
				"bundle-identifier": identifier,
				"bundle-version": version,
				"kind": "software",
				"title": name,
			],
		],],
	]}

	var installManifestData: Data {
		(try? PropertyListSerialization.data(
			fromPropertyList: installManifest,
			format: .xml,
			options: .zero
		)) ?? .init()
	}
}
