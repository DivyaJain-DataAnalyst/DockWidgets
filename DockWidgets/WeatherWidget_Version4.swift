import SwiftUI

struct WeatherWidget_Version4: View {
    @StateObject private var widget = WeatherData_Version4()
    //@StateObject private var settings = UserSettings.shared
    @State private var isLoading = false
    @State private var timeoutTimer: Timer?
    @ObservedObject private var settings = UserSettings.shared
    var body: some View {
        VStack(spacing: 8) {
            if isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if let weatherData = widget.weatherData {
                VStack(spacing: 4) {
                    HStack {
                        if let icon = weatherData.weatherIcon {
                            Image(systemName: icon)
                                .font(.title2)
                        }
                        Text("\(Int(weatherData.temperature))°")
                            .font(.title2)
                            .fontWeight(.bold)
                    }
                    Text(weatherData.condition)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(weatherData.location)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Weather unavailable")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .background(Color.clear)
        .cornerRadius(8)
        .opacity(settings.widgetOpacity)
        .onAppear {
            loadWeatherData()
        }
        .onChange(of: settings.customLocation) {
            loadWeatherData()
        }
    }
    
    private func loadWeatherData() {
        print("🌤️ WeatherWidget: Loading weather data...")
        isLoading = true
        
        // Add timeout to prevent infinite loading
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { _ in
            if self.widget.weatherData == nil && self.isLoading {
                print("🌤️ WeatherWidget: Timeout - falling back to default location")
                self.isLoading = false
                self.loadWeatherForCity("New Delhi")
            }
        }
        
        // Updated to use customLocation for fetching weather
        let city = settings.customLocation.isEmpty ? "New Delhi" : settings.customLocation
        print("🌤️ WeatherWidget: Using city: \(city)")
        timeoutTimer?.invalidate()
        loadWeatherForCity(city)
    }
    
    private func loadWeatherForCity(_ city: String) {
        isLoading = true
        WeatherAPI.shared.getWeatherData(for: city) { result in
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let weatherData):
                    print("🌤️ WeatherWidget: Successfully fetched weather data for \(city)")
                    self.widget.weatherData = weatherData
                case .failure(let error):
                    print("🌤️ WeatherWidget: Weather API error for \(city): \(error)")
                    self.widget.weatherData = nil
                }
            }
        }
    }
}
// MARK: - WeatherData_Version4 Class
class WeatherData_Version4: ObservableObject {
    @Published var weatherData: WeatherData?
}

// MARK: - WeatherWidget Wrapper Class
class WeatherWidget: BaseWidget {
    override func createView() -> AnyView {
        AnyView(WeatherWidget_Version4())
    }
}
