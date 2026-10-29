import Foundation

/// 路径名。三个屏幕读它：设置页副标题、连接详情「路径」行、功能条网络格。
///
/// 住 `SharedUI/` 而不是任何一个 Feature：三处消费方分属两个 Feature 加一个共用零件，
/// 放哪一家都会让别家反向依赖。字面量只在这里出现，由 `LayeringTests` 守着。
func carrierPathText(_ path: CarrierPath) -> String {
    switch path {
    case .direct: "直连"
    case .relay: "中继"
    }
}

/// 没有路径时不说 —— 「未就绪」那一行另有话说，插一个「未知」等于把两件事混成一件。
func carrierPathText(_ path: CarrierPath?) -> String? {
    path.map(carrierPathText)
}
