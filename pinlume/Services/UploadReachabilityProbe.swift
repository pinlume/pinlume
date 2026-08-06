#if !OFFLINE
import Foundation

/// Checks the selected upload service itself before an upload begins. The
/// probe carries no screenshot bytes, credentials, or user content: any HTTP
/// response (including 401/403/404) proves that the configured server is
/// reachable enough to proceed with the authenticated upload.
enum UploadReachabilityProbe {
    private static let timeout: TimeInterval = 3

    static func probeSelectedProvider(completion: @escaping (Result<Void, Error>) -> Void) {
        let provider = UserDefaults.standard.string(forKey: "uploadProvider") ?? "imgbb"
        let endpoint: URL?
        switch provider {
        case "s3":
            endpoint = URL(string: UserDefaults.standard.string(forKey: "s3Endpoint") ?? "")
        case "gdrive":
            endpoint = URL(string: "https://www.googleapis.com/")
        default:
            endpoint = URL(string: "https://api.imgbb.com/")
        }

        guard let endpoint else {
            completion(.failure(unreachableServerError()))
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        URLSession(configuration: configuration).dataTask(with: request) { _, response, error in
            let result: Result<Void, Error>
            if response is HTTPURLResponse {
                result = .success(())
            } else if error != nil {
                result = .failure(unreachableServerError())
            } else {
                result = .failure(unreachableServerError())
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private static func unreachableServerError() -> NSError {
        NSError(
            domain: "UploadReachabilityProbe",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: L("Could not reach the selected upload server. Check its network connection and try again.")]
        )
    }
}
#endif
