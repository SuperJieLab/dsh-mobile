// swift-tools-version:5.9
import PackageDescription

/// 上游 libtailscale 的二进制产物，由 `ios/scripts/build-tailscale-kit.sh` 生成。
///
/// 这里没有源码：包的全部内容就是那个 xcframework。「依赖关系」写在下面一处，
/// 重建之后替换目录即可，工程侧不用再改配置。
let package = Package(
    name: "TailscaleKit",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "TailscaleKit", targets: ["TailscaleKit"])
    ],
    targets: [
        .binaryTarget(name: "TailscaleKit", path: "TailscaleKit.xcframework")
    ]
)
