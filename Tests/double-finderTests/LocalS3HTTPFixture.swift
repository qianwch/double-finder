import Foundation

/// Real loopback HTTP transport for S3Client, isolated from user accounts.
final class LocalS3HTTPFixture {
    let root: URL
    let process = Process()
    let base: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("server.py")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, root.path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while true {
            let byte = pipe.fileHandleForReading.readData(ofLength: 1)
            guard !byte.isEmpty else {
                try? FileManager.default.removeItem(at: root)
                throw NSError(domain: "S3Fixture", code: 1)
            }
            if byte == Data([10]) { break }; line.append(byte)
        }
        base = URL(string: "http://127.0.0.1:" + String(decoding: line, as: UTF8.self))!
    }
    func stop() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: root)
    }
    deinit { stop() }
    func seed(_ key: String, _ bytes: Data) throws {
        var values = (try? JSONDecoder().decode([String: Data].self, from: Data(contentsOf: root.appendingPathComponent("objects.json")))) ?? [:]
        values[key] = bytes
        try JSONEncoder().encode(values).write(to: root.appendingPathComponent("objects.json"))
    }
    func objects() throws -> [String: Data] {
        try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: root.appendingPathComponent("objects.json")))
    }
    var requestCount: Int { ((try? String(contentsOf: root.appendingPathComponent("requests"))) ?? "").split(separator: "\n").count }
    private static let script = #"""
import http.server,json,sys,os,base64,urllib.parse,html
root=sys.argv[1]
def load():
    try:
        with open(root+'/objects.json') as f: return json.load(f)
    except FileNotFoundError: return {}
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def send(self,status,data):
        self.send_response(status); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        with open(root+'/requests','a') as f: f.write('GET '+self.path+'\n')
        url=urllib.parse.urlsplit(self.path); query=urllib.parse.parse_qs(url.query); objects=load()
        if 'list-type' in query:
            prefix=query.get('prefix',[''])[0]
            items=''.join('<Contents><Key>'+html.escape(k)+'</Key><Size>'+str(len(base64.b64decode(v)))+'</Size><LastModified>2026-01-01T00:00:00Z</LastModified></Contents>' for k,v in objects.items() if k.startswith(prefix))
            self.send(200,('<ListBucketResult><IsTruncated>false</IsTruncated>'+items+'</ListBucketResult>').encode())
        else:
            key=urllib.parse.unquote(url.path).split('/',2)[-1]
            self.send(200,base64.b64decode(objects[key])) if key in objects else self.send(404,b'<Error><Message>missing</Message></Error>')
    def do_PUT(self):
        with open(root+'/requests','a') as f: f.write('PUT '+self.path+'\n')
        key=urllib.parse.unquote(urllib.parse.urlsplit(self.path).path).split('/',2)[-1]
        objects=load(); objects[key]=base64.b64encode(self.rfile.read(int(self.headers['Content-Length']))).decode()
        with open(root+'/objects.json','w') as f: json.dump(objects,f)
        self.send(200,b'')
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()
"""#
}
