import WebKit
import Shared

private let log = Logger.browserLogger

enum GeminiClientStatus {
    case input(String)
    case success(String, String.Encoding)
    case redirect(String)
    case failure(String)
    case certificateRequired(String)
}

enum GeminiClientError: Error {
    case badURL
    case noResponder
    case responderUnableToHandle
    case badResponse(GeminiClientStatus)
}

let htmlFooter = """
<script>document.forms[0].onsubmit=function(e){e.preventDefault();document.location=document.location.origin+document.location.pathname+"?"+encodeURI(document.getElementById("q").value)}</script>
"""

class GeminiClient: NSObject {
    static var fingerprints: [String: String] = [:]

    var inputStream: InputStream!
    var done = false
    let urlSchemeTask: WKURLSchemeTask
    let url: URL
    var data: Data
    let start: DispatchTime

    init(url: URL, urlSchemeTask: WKURLSchemeTask) {
        self.urlSchemeTask = urlSchemeTask
        self.url = url
        self.data = Data()
        self.start = DispatchTime.now()
    }

    func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            self._load()
            RunLoop.current.run()
        }
    }

    fileprivate func _load() {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?

        CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault, self.url.host! as CFString, UInt32(self.url.port ?? 1965), &readStream, &writeStream)

        inputStream = readStream!.takeRetainedValue()
        let outputStream: OutputStream = writeStream!.takeRetainedValue()

        inputStream.delegate = self

        inputStream.schedule(in: .current, forMode: .default)
        outputStream.schedule(in: .current, forMode: .default)
        // Enable SSL/TLS on the streams
        inputStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
        outputStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
        let sslSettings = [
            NSString(format: kCFStreamSSLValidatesCertificateChain): kCFBooleanFalse!,
            NSString(format: kCFStreamSSLIsServer): kCFBooleanFalse!
            ] as [NSString : Any]

        inputStream.setProperty(sslSettings, forKey: kCFStreamPropertySSLSettings as Stream.PropertyKey)
        outputStream.setProperty(sslSettings, forKey: kCFStreamPropertySSLSettings as Stream.PropertyKey)

        inputStream.open()
        outputStream.open()

        let request = url.absoluteString + "\r\n"
        guard let data = request.data(using: .utf8) else {
            renderError(error: "Could not send request to \(url.absoluteString)", for: url, to: urlSchemeTask)
            return
        }
        _ = data.withUnsafeBytes {
            outputStream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count)
        }
    }

    func stop() {
        if !done {
            done = true
            inputStream.close()
        }
    }

    fileprivate func asFingerprint(_ s: String) -> String {
        return s.enumerated().compactMap({ ($0 > 0) && ($0 % 16 == 0) ? "\n\($1)" : ($0 > 0) && ($0 % 2 == 0) ? ":\($1)" : "\($1)" }).joined()
    }
}

extension GeminiClient: StreamDelegate {
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            if let trust = self.inputStream.property(forKey: kCFStreamPropertySSLPeerTrust as Stream.PropertyKey) as! SecTrust? {
                let num = SecTrustGetCertificateCount(trust)
                log.debug("Found \(num) certificates")

                for ix in 0..<num {
                    guard let cert = SecTrustGetCertificateAtIndex(trust, ix),
                        let subject = SecCertificateCopySubjectSummary(cert) else {
                            log.debug("Certificate \(ix+1), no subject!")
                            continue
                    }
                    log.debug("Certificate \(ix+1), CN: \(subject)")
                    let fingerprint = (SecCertificateCopyData(cert) as Data).sha256.hexEncodedString.lowercased()
                    log.debug("Fingerprint: \(asFingerprint(fingerprint))")
                    if ix == 0 {
                        GeminiClient.fingerprints[self.url.domainURL.absoluteDisplayString] = asFingerprint(fingerprint)
                    }
                }
            }

            break
        case .hasSpaceAvailable:
            log.error("HasSpaceAvailable")
            break
        case .endEncountered:
            let endReceive = DispatchTime.now()
            var ms = (endReceive.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            log.info("Received data in: \(ms)ms")
            parseResponse(data: data)
            ms = (DispatchTime.now().uptimeNanoseconds - endReceive.uptimeNanoseconds) / 1_000_000
            log.info("Parsed in: \(ms)ms")
            defer {
                done = true
                inputStream.close()
            }
            break
        case .hasBytesAvailable:
            let bufferSize = 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer {
                buffer.deallocate()
            }
            while inputStream.hasBytesAvailable {
                let read = inputStream.read(buffer, maxLength: bufferSize)
                if read < 0 {
                    log.error("HasBytesAvailable but error reading")
                    if let error = inputStream.streamError {
                        renderError(error: error.localizedDescription, for: url, to: urlSchemeTask)
                    } else {
                        renderError(error: "Received error reading from server", for: url, to: urlSchemeTask)
                    }
                    return
                } else if read == 0 {
                    log.debug("EOF")
                    break
                }
                data.append(buffer, count: read)
            }
            log.debug("read \(data.count) bytes")
            break
        case .errorOccurred:
            log.error("ErrorOccurred")
            if let error = inputStream.streamError {
                renderError(error: error.localizedDescription, for: url, to: urlSchemeTask)
            } else {
                renderError(error: "Received error reading from server", for: url, to: urlSchemeTask)
            }
            defer {
                done = true
                inputStream.close()
            }
            break
        default:
            log.error("Unknown error while reading from server")
            renderError(error: "Unknown error while reading from server", for: url, to: urlSchemeTask)
            defer {
                done = true
                inputStream.close()
            }
            break
        }
    }

    fileprivate func parseResponse(data: Data) {
        guard let ix = data.firstIndex(of: 13),
            data[ix+1] == 10,
            let header = String(data: data.prefix(upTo: ix), encoding: .utf8)
            else {
                renderError(error: "Invalid response", for: url, to: urlSchemeTask)
                return
        }
        log.debug("header: \(header)")
        let status = parseStatus(header: header)
        switch status {
        case .success(let mime, let encoding):
            let data = data.dropFirst(ix+2)
            if mime.starts(with: "text/") {
                guard let body = String(data: data, encoding: encoding) else {
                    renderError(error: "Could not parse body with encoding \(encoding)", for: url, to: urlSchemeTask)
                    return
                }
                if mime == "text/gemini" {
                    guard let resp = parseBody(body).data(using: .utf8) else {
                        renderError(error: "Could not parse body", for: url, to: urlSchemeTask)
                        return
                    }
                    urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: -1, textEncodingName: "utf-8"))
                    urlSchemeTask.didReceive(resp)
                } else {
                    guard let resp = body.data(using: .utf8) else {
                        renderError(error: "Could not parse body", for: url, to: urlSchemeTask)
                        return
                    }
                    urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/plain", expectedContentLength: -1, textEncodingName: "utf-8"))
                    urlSchemeTask.didReceive(resp)
                }
            } else {
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: -1,textEncodingName: nil))
                urlSchemeTask.didReceive(data)
            }
            urlSchemeTask.didFinish()
        case .redirect(let to):
            let body = "<meta http-equiv=\"refresh\" content=\"0; URL='\(to)'\" />"
            guard let data = body.data(using: .utf8) else {
                renderError(error: "Could not redirect to \(to)", for: url, to: urlSchemeTask)
                return
            }
            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: -1, textEncodingName: "utf-8"))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        case .input(let question):
            let header = try! String(contentsOfFile: Bundle.main.path(forResource: "GeminiHeader", ofType: "html")!)
            let body = header+"<title>\(question)</title></head><body><h2>\(question)</h2><form><input autocapitalize=off id=q name=q /><hr /><button>Submit</button></form>"+htmlFooter
            guard let data = body.data(using: .utf8) else {
                renderError(error: "Could not render form tosk server's question: \(question)", for: url, to: urlSchemeTask)
                return
            }
            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: -1, textEncodingName: "utf-8"))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        case .certificateRequired(let msg):
            renderError(error: msg, for: url, to: urlSchemeTask)
        case .failure(let error):
            renderError(error: error, for: url, to: urlSchemeTask)
        }
    }

    fileprivate func renderError(error: String, for url: URL, to urlSchemeTask: WKURLSchemeTask) {
        let header = try! String(contentsOfFile: Bundle.main.path(forResource: "GeminiHeader", ofType: "html")!)
        let body = header+"<title>\(error)</title></head><body><h2>\(error)</h2>"
        guard let data = body.data(using: .utf8) else {
            urlSchemeTask.didFailWithError(GeminiClientError.responderUnableToHandle)
            return
        }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: -1, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    fileprivate func parseStatus(header: String) -> GeminiClientStatus {
        switch header.prefix(1) {
        case "1": return .input(String(header.dropFirst(2)))
        case "2":
            do {
                let mimeRegex = try NSRegularExpression(pattern: #"^\d+\s+([^\s;]+)"#, options: [])
                let charsetRegex = try NSRegularExpression(pattern: #"charset\s*=\s*([^\s;]+)"#, options: [])
                let range = NSRange(header.startIndex..<header.endIndex, in: header)
                guard let m1 = mimeRegex.firstMatch(in: header, options: [], range: range),
                    let range1 = Range(m1.range(at: 1), in: header) else {
                        return .failure("cannot parse header")
                }
                let mime = String(header[range1])
                var charset = "utf-8"
                if let m2 = charsetRegex.firstMatch(in: header, options: [], range: range),
                    let range2 = Range(m2.range(at: 1), in: header) {
                    charset = String(header[range2])
                }
                let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                let encoding = String.Encoding(rawValue: nsEncoding)

                return .success(mime, encoding)
            } catch let err as NSError {
                return .failure("cannot parse header: \(err)")
            }
        case "3":
            do {
                let regex = try NSRegularExpression(pattern: #"^\d+\s+(\S.*)$"#, options: [])
                let range = NSRange(header.startIndex..<header.endIndex, in: header)
                guard let m = regex.firstMatch(in: header, options: [], range: range),
                    let range1 = Range(m.range(at: 1), in: header) else {
                        return .failure("cannot parse header")
                }
                let to = String(header[range1])
                return .redirect(to)
            } catch let err as NSError {
                return .failure("cannot parse header: \(err)")
            }
        case "4", "5": return .failure("error: \(header)")
        case "6": return .failure("client certificate required: \(header)")
        default: return .failure("unknown response code: \(header)")
        }
    }

    fileprivate func parseBody(_ content: String) -> String {
        do {
            let h1Regex = try NSRegularExpression(pattern: #"^#\s+(.*)$"#, options: [])
            let h2Regex = try NSRegularExpression(pattern: #"^##\s+(.*)$"#, options: [])
            let h3Regex = try NSRegularExpression(pattern: #"^###\s+(.*)$"#, options: [])
            let listRegex = try NSRegularExpression(pattern: #"^\*\s+([^*]*)$"#, options: [])
            let linkRegex = try NSRegularExpression(pattern: #"^=>\s*(\S*)\s*(.*)?$"#, options: [])

            var pageTitle: String?
            var body = ""
            var pre = false
            for line in content.components(separatedBy: "\n") {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if line.contains("```") {
                    pre = !pre
                    if pre {
                        let l = line.replaceFirstOccurrence(of: "```", with: "<pre><code>")
                        body.append("\(l)\n")
                    } else {
                        let l = line.replaceFirstOccurrence(of: "```", with: "</code></pre>")
                        body.append("\(l)\n")
                    }
                    continue
                }
                if pre {
                    body.append("\(line)\n")
                    continue
                }
                if let m = h1Regex.firstMatch(in: line, options: [], range: range),
                    let range = Range(m.range(at: 1), in: line) {
                    let title = line[range]
                    pageTitle = pageTitle ?? String(title)
                    body.append("<h1>\(title)</h1>\n")
                } else if let m = h2Regex.firstMatch(in: line, options: [], range: range),
                    let range = Range(m.range(at: 1), in: line) {
                    let title = line[range]
                    pageTitle = pageTitle ?? String(title)
                    body.append("<h2>\(title)</h2>\n")
                } else if let m = h3Regex.firstMatch(in: line, options: [], range: range),
                    let range = Range(m.range(at: 1), in: line) {
                    let title = line[range]
                    pageTitle = pageTitle ?? String(title)
                    body.append("<h3>\(title)</h3>\n")
                } else if let m = listRegex.firstMatch(in: line, options: [], range: range),
                    let range = Range(m.range(at: 1), in: line) {
                    let title = line[range]
                    body.append("<li>\(title)</li>\n")
                } else if let m = linkRegex.firstMatch(in: line, options: [], range: range),
                    let range1 = Range(m.range(at: 1), in: line),
                    let range2 = Range(m.range(at: 2), in: line) {
                    let link = line[range1].trimmingCharacters(in: .whitespacesAndNewlines)
                    let title = line[range2].trimmingCharacters(in: .whitespacesAndNewlines)
                    if link == title {
                        body.append("<p><a href=\"\(link)\">\(link)</a></p>\n")
                    } else {
                        body.append("<p><a href=\"\(link)\">\(link)</a> \(title)</p>\n")
                    }
                } else {
                    body.append("<p>\(line)</p>\n")
                }
            }
            let title = pageTitle ?? self.url.absoluteDisplayString
            let header = try! String(contentsOfFile: Bundle.main.path(forResource: "GeminiHeader", ofType: "html")!)
            return header+"<title>\(title)</title></head><body>\n\(body)"
        } catch let err as NSError {
            return "Error: \(err)"
        }
    }
}
