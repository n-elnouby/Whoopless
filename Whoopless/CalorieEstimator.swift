//
//  CalorieEstimator.swift
//  Whoopless
//
//  Estimates active calories burned from heart rate using the Keytel et al.
//  (2005) regression. Drives Apple Fitness's Move ring without requiring a
//  WHOOP subscription.
//
//  Reference: Keytel LR et al., "Prediction of energy expenditure from heart
//  rate monitoring during submaximal exercise", J Sports Sci 2005;23(3):
//  289-97. Population-fit equations; ±15-20 % accuracy is typical for any
//  HR-based estimate, including clinical-grade.
//

import Foundation

enum CalorieEstimator {

    /// Total kcal/min at the given HR. Includes resting metabolic
    /// contribution — caller should subtract resting to get the "active"
    /// component for the Move ring.
    static func keytelKcalPerMin(hr: Int,
                                 weightKg: Double,
                                 ageYears: Int,
                                 sex: BiologicalSex) -> Double {
        let hr_d = Double(hr)
        let w = weightKg
        let a = Double(ageYears)
        let raw: Double
        switch sex {
        case .female:
            raw = (-20.4022 + 0.4472 * hr_d - 0.1263 * w + 0.074 * a) / 4.184
        case .male:
            raw = (-55.0969 + 0.6309 * hr_d + 0.1988 * w + 0.2017 * a) / 4.184
        }
        return max(0, raw)
    }

    /// Active kcal/min above resting baseline. This is what Apple Fitness's
    /// Move ring expects — basal calories are tracked separately by Apple
    /// Health and shouldn't be double-counted.
    static func activeKcalPerMin(hr: Int,
                                 restingHR: Int,
                                 weightKg: Double,
                                 ageYears: Int,
                                 sex: BiologicalSex) -> Double {
        let total = keytelKcalPerMin(hr: hr, weightKg: weightKg, ageYears: ageYears, sex: sex)
        let resting = keytelKcalPerMin(hr: restingHR, weightKg: weightKg, ageYears: ageYears, sex: sex)
        return max(0, total - resting)
    }

    enum BiologicalSex {
        case male, female
    }
}
