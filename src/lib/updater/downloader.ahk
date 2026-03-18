; == 更新下载器（支持取消）==
; 新增：支持下载进度回调

class UpdateDownloader {
    ; 取消标志
    static IsCancelled := false
    ; HTTP请求对象（用于中止）
    static CurrentHttp := ""
    ; 当前下载会话（用于异步分块下载与进度上报）
    static CurrentSession := ""
    
    ; 取消当前下载
    static Cancel() {
        this.IsCancelled := true
        ; 尝试中止HTTP请求
        if (this.CurrentSession != "") {
            this.CurrentSession.Cancel()
            return
        }
        if (this.CurrentHttp != "") {
            try {
                this.CurrentHttp.Abort()
            }
        }
    }
    
    ; 重置取消状态（开始新下载前调用）
    static ResetCancel() {
        this.IsCancelled := false
        this.CurrentHttp := ""
        this.CurrentSession := ""
    }
    
    ; 下载文件
    ; params: 包含以下字段的对象
    ;   - downloadUrl: 下载链接
    ;   - localVersion: 当前版本
    ;   - remoteVersion: 远程版本
    ;   - onProgress: 进度回调函数(可选)
    ;   - onComplete: 完成回调函数
    ;   - onError: 错误回调函数
    ;   - onCancel: 取消回调函数(可选)
    static Download(params) {
        ; 重置取消状态
        this.ResetCancel()
        
        downloadUrl := params.downloadUrl
        remoteVersion := params.remoteVersion
        
        ; 生成临时文件路径
        tempDir := A_Temp "\ArknightsFrameAssistant"
        if !DirExist(tempDir)
            DirCreate(tempDir)
        
        tempFile := tempDir "\AFA_" remoteVersion "_update.exe"
        
        try {
            ; 使用 WinHttpRequest 进行下载
            ; 检查是否已取消
            ; 检查HTTP状态
            ; 再次检查是否已取消（在保存文件前）
            ; 获取响应体并保存到文件
            ; 再次检查是否已取消（在验证前）
            ; 验证文件是否成功创建
            ; 发布下载完成事件
            ; 调用完成回调（如果提供且是函数）
            ; 新实现：以上流程改为 PowerShell 子进程分块下载，由会话对象轮询进度文件并上报进度
            session := UpdateDownloadSession(params, downloadUrl, tempFile, remoteVersion)
            this.CurrentSession := session
            session.Start()
            while !session.IsDone {
                session.Poll()
                Sleep(100)
            }
            return session.Result
            
        } catch Error as e {
            ; 检查是否是取消导致的错误
            if (this.IsCancelled) {
                if (params.HasProp("onCancel") && (Type(params.onCancel) = "Func" || Type(params.onCancel) = "Closure" || Type(params.onCancel) = "BoundFunc")) {
                    callback := params.onCancel
                    callback.Call({message: "用户取消了下载"})
                }
                return {success: false, error: "用户取消了下载", cancelled: true}
            }
            
            errorInfo := {
                message: "下载失败: " e.Message,
                url: downloadUrl,
                version: remoteVersion
            }
            
            ; 发布下载错误事件
            EventBus.Publish("UpdateDownloadError", errorInfo)
            
            ; 调用错误回调（如果提供且是函数）
            if (params.HasProp("onError") && (Type(params.onError) = "Func" || Type(params.onError) = "Closure" || Type(params.onError) = "BoundFunc")) {
                callback := params.onError
                callback.Call(errorInfo)
            }
            
            return {
                success: false,
                error: errorInfo.message
            }
        } finally {
            ; 清理HTTP引用
            this.CurrentHttp := ""
            this.CurrentSession := ""
        }
    }
    
    ; 获取临时文件路径（用于检查之前的下载）
    static GetTempFilePath(version) {
        tempDir := A_Temp "\ArknightsFrameAssistant"
        return tempDir "\AFA_" version "_update.exe"
    }
    
    ; 验证下载的文件是否完整（简单的存在性检查）
    static VerifyDownload(filePath) {
        if !FileExist(filePath) {
            return false
        }
        
        ; 获取文件大小
        try {
            fileSize := FileGetSize(filePath)
            return fileSize > 0
        } catch {
            return false
        }
    }
}

; 下载会话：负责异步分块下载、进度上报和取消清理
class UpdateDownloadSession {
    __New(params, downloadUrl, tempFile, remoteVersion) {
        this.Params := params
        this.DownloadUrl := downloadUrl
        this.TempFile := tempFile
        this.RemoteVersion := remoteVersion
        this.Http := ""
        this.FileObj := ""
        this.IsDone := false
        this.IsCancelled := false
        this.TotalBytes := 0
        this.DownloadedBytes := 0
        this.HasContentLength := false
        this.Result := {success: false, error: "下载未开始"}
        this.WorkerPid := 0
        this.WorkerScript := ""
        this.ProgressFile := ""
    }

    ; 启动异步下载
    Start() {
        tempDir := A_Temp "\ArknightsFrameAssistant"
        if !DirExist(tempDir)
            DirCreate(tempDir)

        this.ProgressFile := tempDir "\download_" A_TickCount "_state.txt"
        this.WorkerScript := tempDir "\download_" A_TickCount "_worker.ps1"

        if FileExist(this.TempFile) {
            try FileDelete(this.TempFile)
        }
        if FileExist(this.ProgressFile) {
            try FileDelete(this.ProgressFile)
        }
        if FileExist(this.WorkerScript) {
            try FileDelete(this.WorkerScript)
        }

        FileAppend(this.BuildWorkerScript(), this.WorkerScript, "UTF-8")
        command := 'powershell -NoProfile -ExecutionPolicy Bypass -File "' this.WorkerScript '" -Url "' this.DownloadUrl '" -OutFile "' this.TempFile '" -StateFile "' this.ProgressFile '"'
        Run(command, , "Hide", &pid)
        this.WorkerPid := pid
    }

    ; 取消下载
    Cancel() {
        if (this.IsDone || this.IsCancelled)
            return

        this.IsCancelled := true
        UpdateDownloader.IsCancelled := true

        if (this.WorkerPid) {
            try ProcessClose(this.WorkerPid)
        }
    }

    ; 轮询下载进度与下载结果
    Poll() {
        if (this.IsDone)
            return

        state := this.ReadState()
        if (state.Status = "downloading") {
            this.DownloadedBytes := state.DownloadedBytes
            this.TotalBytes := state.TotalBytes
            this.HasContentLength := state.HasContentLength
            this.ReportProgress()
        } else if (state.Status = "completed") {
            this.DownloadedBytes := state.DownloadedBytes
            this.TotalBytes := state.TotalBytes
            this.HasContentLength := state.HasContentLength
            this.CompleteSuccess()
            return
        } else if (state.Status = "error") {
            this.Fail(state.ErrorMessage != "" ? state.ErrorMessage : "下载失败")
            return
        }

        if (this.IsCancelled && !ProcessExist(this.WorkerPid)) {
            this.CompleteCancelled()
            return
        }

        if (!this.IsCancelled && this.WorkerPid && !ProcessExist(this.WorkerPid) && state.Status = "") {
            this.Fail("下载失败: 下载进程异常退出")
        }
    }

    ; 上报下载进度
    ReportProgress(forceComplete := false) {
        if !(this.Params.HasProp("onProgress") && (Type(this.Params.onProgress) = "Func" || Type(this.Params.onProgress) = "Closure" || Type(this.Params.onProgress) = "BoundFunc"))
            return

        if (this.IsDone || this.IsCancelled)
            return

        totalBytes := this.HasContentLength ? this.TotalBytes : 0
        isIndeterminate := !this.HasContentLength
        percent := forceComplete ? 100 : 0

        if (!isIndeterminate && this.TotalBytes > 0)
            percent := Min(100, Max(0, Floor((this.DownloadedBytes * 100) / this.TotalBytes)))

        this.Params.onProgress.Call({
            downloadedBytes: this.DownloadedBytes,
            totalBytes: totalBytes,
            percent: percent,
            isIndeterminate: isIndeterminate
        })
    }

    ; 统一失败处理
    Fail(message) {
        if (this.IsDone)
            return

        this.KillWorker()
        this.DeleteTempFile()
        this.CleanupWorkerFiles()

        errorInfo := {
            message: message,
            url: this.DownloadUrl,
            version: this.RemoteVersion
        }

        ; 发布下载错误事件
        EventBus.Publish("UpdateDownloadError", errorInfo)
        
        ; 调用错误回调（如果提供且是函数）
        if (this.Params.HasProp("onError") && (Type(this.Params.onError) = "Func" || Type(this.Params.onError) = "Closure" || Type(this.Params.onError) = "BoundFunc")) {
            callback := this.Params.onError
            callback.Call(errorInfo)
        }

        this.Result := {
            success: false,
            error: message
        }
        this.IsDone := true
    }

    ; 统一取消处理
    CompleteCancelled() {
        if (this.IsDone)
            return

        this.KillWorker()
        this.DeleteTempFile()
        this.CleanupWorkerFiles()

        if (this.Params.HasProp("onCancel") && (Type(this.Params.onCancel) = "Func" || Type(this.Params.onCancel) = "Closure" || Type(this.Params.onCancel) = "BoundFunc")) {
            callback := this.Params.onCancel
            callback.Call({message: "用户取消了下载"})
        }

        this.Result := {
            success: false,
            error: "用户取消了下载",
            cancelled: true
        }
        this.IsDone := true
    }

    ; 下载完成后校验文件并回调完成逻辑
    CompleteSuccess() {
        if (this.IsDone)
            return

        this.CleanupWorkerFiles()

        if !UpdateDownloader.VerifyDownload(this.TempFile) {
            this.Fail("文件保存失败")
            return
        }

        if (this.HasContentLength && this.TotalBytes > 0)
            this.DownloadedBytes := this.TotalBytes
        else
            this.DownloadedBytes := FileGetSize(this.TempFile)

        this.ReportProgress(true)

        result := {
            success: true,
            tempFile: this.TempFile,
            remoteVersion: this.RemoteVersion
        }

        ; 发布下载完成事件
        EventBus.Publish("UpdateDownloadComplete", result)
        
        ; 调用完成回调（如果提供且是函数）
        if (this.Params.HasProp("onComplete") && (Type(this.Params.onComplete) = "Func" || Type(this.Params.onComplete) = "Closure" || Type(this.Params.onComplete) = "BoundFunc")) {
            callback := this.Params.onComplete
            callback.Call(result)
        }

        this.Result := result
        this.IsDone := true
    }

    ; 关闭后台下载进程
    KillWorker() {
        if (this.WorkerPid && ProcessExist(this.WorkerPid)) {
            try ProcessClose(this.WorkerPid)
        }
        this.WorkerPid := 0
    }

    ; 删除临时文件
    DeleteTempFile() {
        if FileExist(this.TempFile) {
            try FileDelete(this.TempFile)
        }
    }

    ; 清理状态文件和脚本文件
    CleanupWorkerFiles() {
        if FileExist(this.ProgressFile) {
            try FileDelete(this.ProgressFile)
        }
        if FileExist(this.WorkerScript) {
            try FileDelete(this.WorkerScript)
        }
        this.ProgressFile := ""
        this.WorkerScript := ""
    }

    ; 读取进度状态文件
    ReadState() {
        result := {
            Status: "",
            DownloadedBytes: this.DownloadedBytes,
            TotalBytes: this.TotalBytes,
            HasContentLength: this.HasContentLength,
            ErrorMessage: ""
        }

        if !FileExist(this.ProgressFile)
            return result

        try content := FileRead(this.ProgressFile, "UTF-8")
        catch
            return result

        status := this.ReadStateValue(content, "Status")
        if (status != "")
            result.Status := status

        downloadedBytes := this.ReadStateValue(content, "DownloadedBytes")
        if (downloadedBytes != "")
            result.DownloadedBytes := this.ParseNumber(downloadedBytes, result.DownloadedBytes)

        totalBytes := this.ReadStateValue(content, "TotalBytes")
        if (totalBytes != "")
            result.TotalBytes := this.ParseNumber(totalBytes, result.TotalBytes)

        hasContentLength := this.ReadStateValue(content, "HasContentLength")
        if (hasContentLength != "")
            result.HasContentLength := hasContentLength = "1"

        errorMessage := this.ReadStateValue(content, "Error")
        if (errorMessage != "")
            result.ErrorMessage := errorMessage

        return result
    }

    ; 从状态文件中读取指定键值
    ReadStateValue(content, key) {
        pattern := "(?m)^" key "=(.*)$"
        if RegExMatch(content, pattern, &match)
            return match[1]
        return ""
    }

    ; 新增：安全解析数字，避免半写入状态文件导致类型错误
    ParseNumber(value, fallback := 0) {
        value := Trim(value)
        if (value = "")
            return fallback
        if RegExMatch(value, "^-?\d+$")
            return value + 0
        return fallback
    }

    ; 新增：兼容旧环境的数组拼接
    JoinLines(lines, delimiter := "`r`n") {
        result := ""
        for index, line in lines {
            if (index = 1)
                result := line
            else
                result .= delimiter line
        }
        return result
    }

    ; 生成 PowerShell 下载脚本
    BuildWorkerScript() {
        lines := []
        lines.Push("param(")
        lines.Push("    [string]`$Url,")
        lines.Push("    [string]`$OutFile,")
        lines.Push("    [string]`$StateFile")
        lines.Push(")")
        lines.Push("")
        lines.Push("`$ErrorActionPreference = 'Stop'")
        lines.Push("")
        lines.Push("function Write-State {")
        lines.Push("    param(")
        lines.Push("        [string]`$Status,")
        lines.Push("        [long]`$DownloadedBytes,")
        lines.Push("        [long]`$TotalBytes,")
        lines.Push("        [bool]`$HasContentLength,")
        lines.Push("        [string]`$ErrorMessage = ''")
        lines.Push("    )")
        lines.Push("")
        lines.Push("    `$lines = @(")
        lines.Push("        'Status=`$Status',")
        lines.Push("        'DownloadedBytes=`$DownloadedBytes',")
        lines.Push("        'TotalBytes=`$TotalBytes',")
        lines.Push("        'HasContentLength=`$([int]`$HasContentLength)',")
        lines.Push("        'Error=`$ErrorMessage'")
        lines.Push("    )")
        lines.Push("")
        lines.Push("    [System.IO.File]::WriteAllLines(`$StateFile, `$lines, [System.Text.Encoding]::UTF8)")
        lines.Push("}")
        lines.Push("")
        lines.Push("`$response = `$null")
        lines.Push("`$responseStream = `$null")
        lines.Push("`$fileStream = `$null")
        lines.Push("")
        lines.Push("try {")
        lines.Push("    Write-State -Status 'starting' -DownloadedBytes 0 -TotalBytes 0 -HasContentLength `$false")
        lines.Push("")
        lines.Push("    `$request = [System.Net.HttpWebRequest]::Create(`$Url)")
        lines.Push("    `$response = `$request.GetResponse()")
        lines.Push("    `$responseStream = `$response.GetResponseStream()")
        lines.Push("")
        lines.Push("    `$totalBytes = [long]`$response.ContentLength")
        lines.Push("    `$hasContentLength = `$totalBytes -gt 0")
        lines.Push("    `$downloadedBytes = 0L")
        lines.Push("    `$buffer = New-Object byte[] 65536")
        lines.Push("")
        lines.Push("    `$fileStream = [System.IO.File]::Open(`$OutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)")
        lines.Push("    Write-State -Status 'downloading' -DownloadedBytes 0 -TotalBytes `$totalBytes -HasContentLength `$hasContentLength")
        lines.Push("")
        lines.Push("    while ((`$read = `$responseStream.Read(`$buffer, 0, `$buffer.Length)) -gt 0) {")
        lines.Push("        `$fileStream.Write(`$buffer, 0, `$read)")
        lines.Push("        `$downloadedBytes += `$read")
        lines.Push("        Write-State -Status 'downloading' -DownloadedBytes `$downloadedBytes -TotalBytes `$totalBytes -HasContentLength `$hasContentLength")
        lines.Push("    }")
        lines.Push("")
        lines.Push("    `$fileStream.Flush()")
        lines.Push("    Write-State -Status 'completed' -DownloadedBytes `$downloadedBytes -TotalBytes `$totalBytes -HasContentLength `$hasContentLength")
        lines.Push("    exit 0")
        lines.Push("}")
        lines.Push("catch {")
        lines.Push("    `$msg = `$_.Exception.Message -replace '`r|`n', ' '")
        lines.Push("    try {")
        lines.Push("        if (Test-Path `$OutFile) {")
        lines.Push("            Remove-Item `$OutFile -Force")
        lines.Push("        }")
        lines.Push("    } catch {}")
        lines.Push("    Write-State -Status 'error' -DownloadedBytes 0 -TotalBytes 0 -HasContentLength `$false -ErrorMessage `$msg")
        lines.Push("    exit 1")
        lines.Push("}")
        lines.Push("finally {")
        lines.Push("    if (`$fileStream) { `$fileStream.Dispose() }")
        lines.Push("    if (`$responseStream) { `$responseStream.Dispose() }")
        lines.Push("    if (`$response) { `$response.Dispose() }")
        lines.Push("}")
        return this.JoinLines(lines, "`r`n")
    }
}
