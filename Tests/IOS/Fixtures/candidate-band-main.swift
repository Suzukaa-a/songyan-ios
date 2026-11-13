import Foundation

// Production candidate-band rule, compiled from its source section.

var failures = 0

func check(_ value: @autoclosure () -> Bool, _ label: String) {
    if value() {
        print("PASS: " + label)
    } else {
        failures += 1
        print("FAIL: " + label)
    }
}

func band(
    definition: Bool = false, requires: Bool = true, letters: Bool = false, composing: Bool = false,
    wide: Bool = false
) -> Bool {
    KeyboardCandidateBand.required(
        definitionPage: definition, definitionRequires: requires, lettersPage: letters,
        keepsForComposition: composing, wideDismiss: wide)
}

check(!band(), "a phone's idle 123 page drops the band")
check(band(composing: true), "123 keeps the band for a live composition")
check(band(letters: true), "ABC keeps its word suggestions")
check(band(wide: true), "a wide surface keeps the band on 123 for the dismiss entry")
check(band(definition: true), "a layout's letters follow the layout")
check(!band(definition: true, requires: false, wide: true), "a layout without a candidate area stays without one")

if failures > 0 { fatalError("\(failures) candidate band checks failed") }
print("candidate band checks passed")
