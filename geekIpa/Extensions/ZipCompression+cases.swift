//
//  ZipCompression+cases.swift
//  geekIpa
//
//  Created by samara on 22.04.2025.
//

import Zip

extension ZipCompression {
	static var allCases: [ZipCompression] {
		[.NoCompression, .BestSpeed, .DefaultCompression, .BestCompression]
	}

	/// 默认压缩档位（DefaultCompression 在 allCases 中的下标）
	static var defaultIndex: Int { 2 }
	
}
