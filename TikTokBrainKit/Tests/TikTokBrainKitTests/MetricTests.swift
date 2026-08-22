import XCTest
@testable import TikTokBrainKit

final class MetricTests: XCTestCase {
    func testWeights() {
        XCTAssertEqual(Metric.localize("8 oz cream cheese"), "225 g cream cheese")
        XCTAssertEqual(Metric.localize("2 lbs chicken thighs"), "900 g chicken thighs")
        XCTAssertEqual(Metric.localize("3 pounds of potatoes"), "1.4 kg of potatoes")
        XCTAssertEqual(Metric.localize("2-3 oz butter"), "55–85 g butter")
    }

    func testVolumes() {
        XCTAssertEqual(Metric.localize("1/2 cup milk"), "120 ml milk")
        XCTAssertEqual(Metric.localize("½ cup sugar"), "120 ml sugar")
        XCTAssertEqual(Metric.localize("1 1/2 cups flour"), "360 ml flour")
        XCTAssertEqual(Metric.localize("4 fl oz water"), "120 ml water")
        XCTAssertEqual(Metric.localize("1 pint cream"), "475 ml cream")
        XCTAssertEqual(Metric.localize("1 gallon stock"), "3.8 l stock")
    }

    func testTemperaturesAndLengths() {
        XCTAssertEqual(Metric.localize("Bake at 350°F for 20 minutes"), "Bake at 180°C for 20 minutes")
        XCTAssertEqual(Metric.localize("preheat to 400 degrees F"), "preheat to 200°C")
        XCTAssertEqual(Metric.localize("roast at 425-450°F"), "roast at 220–230°C")
        XCTAssertEqual(Metric.localize("cut into 2 inch pieces"), "cut into 5 cm pieces")
    }

    /// Spoons are how European recipes are written too; metric text stays as it is.
    func testLeavesMetricAndSpoonsAlone() {
        XCTAssertEqual(Metric.localize("1 tsp salt"), "1 tsp salt")
        XCTAssertEqual(Metric.localize("200 g flour, 100 ml milk"), "200 g flour, 100 ml milk")
        XCTAssertEqual(Metric.localize("Rinse in cold water"), "Rinse in cold water")
        XCTAssertEqual(Metric.localize("Ozzy's 20 minute chili"), "Ozzy's 20 minute chili")
    }
}
