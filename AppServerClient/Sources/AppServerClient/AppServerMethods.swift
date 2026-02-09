public enum AppServerMethods {
    public static let initialize = "initialize"
    public static let initialized = "initialized"

    public static let threadStart = "thread/start"
    public static let threadResume = "thread/resume"
    public static let threadList = "thread/list"
    public static let threadArchive = "thread/archive"

    public static let turnStart = "turn/start"
    public static let turnInterrupt = "turn/interrupt"

    public static let reviewStart = "review/start"
    public static let commandExec = "command/exec"

    public static let modelList = "model/list"
    public static let skillsList = "skills/list"

    public static let mcpServerOauthLogin = "mcpServer/oauth/login"
    public static let mcpServerStatusList = "mcpServerStatus/list"

    public static let feedbackUpload = "feedback/upload"

    public static let configRead = "config/read"
    public static let configValueWrite = "config/value/write"
    public static let configBatchWrite = "config/batchWrite"
}