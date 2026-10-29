import os

/// os.Logger 모음. 경로에는 사용자 이름이 들어가므로 로그에 남길 때는 privacy: .private 를 쓴다.
public enum Log {
    public static let subsystem = "com.wjbyun.Storager"

    public static let scan = Logger(subsystem: subsystem, category: "scan")
    public static let store = Logger(subsystem: subsystem, category: "store")
    public static let cleanup = Logger(subsystem: subsystem, category: "cleanup")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
