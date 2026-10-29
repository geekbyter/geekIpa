//
//  UTType++.swift
//  geekIpa
//
//  自定义文件类型。
//  注意：UTType(filenameExtension:) 在系统不认识该后缀时会返回 nil，
//  原先用 `!` 强制解包，一旦某台设备不识别（例如 deb）会在首次访问时崩溃，
//  这里统一退回 .data，保证不会崩。
//

import UniformTypeIdentifiers

extension UTType {
	static var dylib: UTType {
		UTType(filenameExtension: "dylib") ?? .data
	}

	static var deb: UTType {
		UTType(filenameExtension: "deb") ?? .data
	}

	static var ipa: UTType {
		UTType(filenameExtension: "ipa") ?? .data
	}

	static var tipa: UTType {
		UTType(filenameExtension: "tipa") ?? .data
	}

	static var entitlements: UTType {
		UTType(filenameExtension: "entitlements", conformingTo: .data) ?? .data
	}

	static var p12: UTType {
		UTType(filenameExtension: "p12", conformingTo: .data) ?? .data
	}

	static var mobileProvision: UTType {
		UTType(filenameExtension: "mobileprovision", conformingTo: .data) ?? .data
	}
}
