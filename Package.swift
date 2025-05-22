// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.


import PackageDescription



let package = Package(
	name: "PopBluetooth",
	
	platforms: [
		.iOS(.v15),
		.macOS(.v14),
		.tvOS(.v16)
	],
	

	products: [
		.library(
			name: "PopBluetooth",
			targets: [
				"PopBluetooth"
			]),
	],
	targets: [

		.target(
			name: "PopBluetooth"
			)
		
	]
)
