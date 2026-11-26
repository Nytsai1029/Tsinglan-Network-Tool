import Foundation

/// Chooses the right portal dialect for an account and normalises results.
public final class PortalService {
    private let srun: SrunClient
    private let huawei: HuaweiACClient

    public init(srun: SrunClient = SrunClient(), huawei: HuaweiACClient = HuaweiACClient()) {
        self.srun = srun
        self.huawei = huawei
    }

    public func status(clientIP: String, base: URL, settings: PortalSettings,
                       source: EgressSource?) -> PortalStatus {
        switch settings.kind {
        case .huaweiAC:
            return huawei.status(base: base, settings: settings, source: source)
        case .srun:
            let status = srun.status(clientIP: clientIP, base: base, settings: settings, source: source)
            return PortalStatus(isOnline: status.isOnline,
                                reachable: status.reachable,
                                userName: status.userName,
                                onlineIP: status.onlineIP,
                                productName: status.productName,
                                balance: status.balance,
                                errorMessage: status.errorMessage)
        }
    }

    public func logout(username: String, clientIP: String, base: URL,
                       settings: PortalSettings, source: EgressSource?) throws {
        switch settings.kind {
        case .huaweiAC:
            throw PortalError.portalError("华为 AC 门户暂不支持程序内注销，请在浏览器中操作")
        case .srun:
            try srun.logout(username: username, clientIP: clientIP, base: base,
                            settings: settings, source: source)
        }
    }

    public func login(account: Account, password: String, clientIP: String,
                      settings: PortalSettings, source: EgressSource?) throws -> PortalLoginResult {
        switch settings.kind {
        case .huaweiAC:
            return try huawei.login(account: account, password: password,
                                    settings: settings, source: source)
        case .srun:
            let result = try srun.login(account: account, password: password,
                                        clientIP: clientIP, settings: settings, source: source)
            return PortalLoginResult(onlineIP: result.onlineIP,
                                     accessToken: result.accessToken,
                                     message: result.message)
        }
    }
}
