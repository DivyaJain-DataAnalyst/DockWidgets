import Foundation
import CoreLocation

class WeatherAPI {
    static let shared = WeatherAPI()
    private let apiKey = "05b6ac7969dbf1e0d32041e646e75fd8"
    private let baseURL = "https://api.openweathermap.org/data/2.5/weather"
    
    func fetchWeather(for location: CLLocation, completion: @escaping (Result<WeatherData, WeatherError>) -> Void) {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let urlString = "\(baseURL)?lat=\(lat)&lon=\(lon)&appid=\(apiKey)&units=metric"
        
        print("🌤️ Weather API URL: \(urlString)")
        
        guard let url = URL(string: urlString) else {
            print("❌ Invalid URL: \(urlString)")
            completion(.failure(.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("❌ Network error: \(error.localizedDescription)")
                completion(.failure(.networkError(error)))
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("🌐 HTTP Status: \(httpResponse.statusCode)")
                if httpResponse.statusCode != 200 {
                    completion(.failure(.httpError(httpResponse.statusCode)))
                    return
                }
            }
            
            guard let data = data else {
                print("❌ No data received")
                completion(.failure(.noData))
                return
            }
            
            print("📦 Received data: \(data.count) bytes")
            
            do {
                let weatherResponse = try JSONDecoder().decode(WeatherResponse.self, from: data)
                print("✅ Successfully decoded weather data for: \(weatherResponse.name)")
                
                let weatherData = WeatherData(
                    location: weatherResponse.name,
                    temperature: Int(weatherResponse.main.temp),
                    condition: weatherResponse.weather.first?.description.capitalized ?? "Unknown",
                    weatherIcon: self.getWeatherIcon(for: weatherResponse.weather.first?.main ?? ""),
                    humidity: weatherResponse.main.humidity ?? 0,
                    windSpeed: weatherResponse.wind?.speed ?? 0.0,
                    feelsLike: Int(weatherResponse.main.feelsLike ?? weatherResponse.main.temp)
                )
                completion(.success(weatherData))
            } catch {
                print("❌ JSON decode error: \(error)")
                if let jsonString = String(data: data, encoding: .utf8) {
                    print("📄 Raw JSON: \(jsonString)")
                }
                completion(.failure(.decodingError(error)))
            }
        }.resume()
    }
    
    func fetchWeatherByCity(_ city: String, completion: @escaping (Result<WeatherData, WeatherError>) -> Void) {
        guard let encodedCity = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            completion(.failure(.invalidURL))
            return
        }
        
        let urlString = "\(baseURL)?q=\(encodedCity)&appid=\(apiKey)&units=metric"
        
        print("🌤️ Weather API URL (city): \(urlString)")
        
        guard let url = URL(string: urlString) else {
            completion(.failure(.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("❌ Network error: \(error.localizedDescription)")
                completion(.failure(.networkError(error)))
                return
            }
            
            guard let data = data else {
                completion(.failure(.noData))
                return
            }
            
            do {
                let weatherResponse = try JSONDecoder().decode(WeatherResponse.self, from: data)
                let weatherData = WeatherData(
                    location: weatherResponse.name,
                    temperature: Int(weatherResponse.main.temp),
                    condition: weatherResponse.weather.first?.description.capitalized ?? "Unknown",
                    weatherIcon: self.getWeatherIcon(for: weatherResponse.weather.first?.main ?? ""),
                    humidity: weatherResponse.main.humidity ?? 0,
                    windSpeed: weatherResponse.wind?.speed ?? 0.0,
                    feelsLike: Int(weatherResponse.main.feelsLike ?? weatherResponse.main.temp)
                )
                completion(.success(weatherData))
            } catch {
                print("❌ JSON decode error: \(error)")
                completion(.failure(.decodingError(error)))
            }
        }.resume()
    }
    
    func getWeatherData(for city: String, completion: @escaping (Result<WeatherData, WeatherError>) -> Void) {
        fetchWeatherByCity(city, completion: completion)
    }
    
    private func getWeatherIcon(for condition: String) -> String {
        switch condition.lowercased() {
        case "clear": return "☀️"
        case "clouds": return "☁️"
        case "rain": return "🌧️"
        case "snow": return "❄️"
        case "thunderstorm": return "⛈️"
        case "drizzle": return "🌦️"
        case "mist", "fog": return "🌫️"
        default: return "🌤️"
        }
    }
}

// MARK: - Error Types
enum WeatherError: Error {
    case invalidURL
    case noData
    case httpError(Int)
    case networkError(Error)
    case decodingError(Error)
    
    var localizedDescription: String {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .noData:
            return "No data received"
        case .httpError(let code):
            return "HTTP Error: \(code)"
        case .networkError(let error):
            return "Network Error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Decoding Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Data Models
struct WeatherResponse: Codable {
    let name: String
    let main: Main
    let weather: [Weather]
    let wind: Wind?
    
    struct Main: Codable {
        let temp: Double
        let humidity: Int?
        let feelsLike: Double?
        
        enum CodingKeys: String, CodingKey {
            case temp
            case humidity
            case feelsLike = "feels_like"
        }
    }
    
    struct Weather: Codable {
        let main: String
        let description: String
    }
    
    struct Wind: Codable {
        let speed: Double
    }
}

struct WeatherData: Identifiable {
    let id = UUID()
    let location: String
    let temperature: Int
    let condition: String
    let weatherIcon: String
    let humidity: Int
    let windSpeed: Double
    let feelsLike: Int
}
