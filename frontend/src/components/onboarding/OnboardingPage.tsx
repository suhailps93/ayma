import { useState, useEffect } from "react";
import { supabase } from "../../lib/supabase";
import { useLocation } from "../../hooks/use-location";
import "./OnboardingPage.scss";

interface OnboardingData {
  display_name: string;
  age: string;
  gender: string;
  interested_in: string[];
  age_min: string;
  age_max: string;
  location_region: string;
}

const GENDERS = ["Man", "Woman", "Non-binary", "Other", "Prefer not to say"];
const INTERESTED_IN = ["Men", "Women", "Non-binary people", "Everyone"];

interface Props {
  userId: string;
  onComplete: () => void;
}

export default function OnboardingPage({ userId, onComplete }: Props) {
  const [step, setStep] = useState(0);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [locationInput, setLocationInput] = useState("");
  const [showSuggestions, setShowSuggestions] = useState(false);

  const { permission, detectedLocation, requestLocation, searchPlaces, suggestions, searchLoading } = useLocation();

  const [data, setData] = useState<OnboardingData>({
    display_name: "",
    age: "",
    gender: "",
    interested_in: [],
    age_min: "18",
    age_max: "45",
    location_region: "",
  });

  // When location is auto-detected, fill the field
  useEffect(() => {
    if (detectedLocation && !data.location_region) {
      setData((d) => ({ ...d, location_region: detectedLocation }));
      setLocationInput(detectedLocation);
    }
  }, [detectedLocation]);

  const set = (key: keyof OnboardingData, value: string | string[]) =>
    setData((d) => ({ ...d, [key]: value }));

  const toggleInterest = (val: string) => {
    const cur = data.interested_in;
    set("interested_in", cur.includes(val) ? cur.filter((v) => v !== val) : [...cur, val]);
  };

  const canAdvance = () => {
    if (step === 0) return data.display_name.trim() && data.age.trim() && parseInt(data.age) >= 18;
    if (step === 1) return !!data.gender;
    if (step === 2) return data.interested_in.length > 0;
    if (step === 3) return !!data.location_region.trim();
    return false;
  };

  const handleLocationInput = (val: string) => {
    setLocationInput(val);
    set("location_region", val);
    setShowSuggestions(true);
    searchPlaces(val);
  };

  const handleSave = async () => {
    setSaving(true);
    setError(null);
    try {
      const { error } = await supabase
        .from("user_profiles")
        .update({
          display_name: data.display_name.trim(),
          age: parseInt(data.age),
          gender: data.gender,
          location_region: data.location_region.trim(),
          matching_prefs: {
            interested_in: data.interested_in,
            age_min: parseInt(data.age_min),
            age_max: parseInt(data.age_max),
          },
          onboarding_complete: true,
        })
        .eq("id", userId);

      if (error) throw error;
      onComplete();
    } catch (e: any) {
      setError(e.message || "Something went wrong. Try again.");
      setSaving(false);
    }
  };

  const steps = [
    // Step 0: Name + Age
    <div className="step" key="step0">
      <h2>Let's start with the basics</h2>
      <p className="step-hint">This helps us find people who are right for you.</p>

      <label>What's your name?</label>
      <input
        type="text"
        placeholder="First name"
        value={data.display_name}
        onChange={(e) => set("display_name", e.target.value)}
        autoFocus
      />

      <label>How old are you?</label>
      <input
        type="number"
        placeholder="Age"
        min={18}
        max={120}
        value={data.age}
        onChange={(e) => set("age", e.target.value)}
      />
      {data.age && parseInt(data.age) < 18 && (
        <p className="field-error">You must be 18 or older.</p>
      )}
    </div>,

    // Step 1: Gender
    <div className="step" key="step1">
      <h2>How do you identify?</h2>
      <p className="step-hint">This is shown on your profile.</p>
      <div className="option-grid">
        {GENDERS.map((g) => (
          <button
            key={g}
            className={`option-btn ${data.gender === g ? "selected" : ""}`}
            onClick={() => set("gender", g)}
          >
            {g}
          </button>
        ))}
      </div>
    </div>,

    // Step 2: Interested in + age range
    <div className="step" key="step2">
      <h2>Who are you interested in?</h2>
      <p className="step-hint">Select all that apply.</p>
      <div className="option-grid">
        {INTERESTED_IN.map((g) => (
          <button
            key={g}
            className={`option-btn ${data.interested_in.includes(g) ? "selected" : ""}`}
            onClick={() => toggleInterest(g)}
          >
            {g}
          </button>
        ))}
      </div>

      <label className="range-label">Age range you're open to</label>
      <div className="age-range">
        <div className="range-field">
          <span>From</span>
          <input
            type="number"
            min={18}
            max={100}
            value={data.age_min}
            onChange={(e) => set("age_min", e.target.value)}
          />
        </div>
        <div className="range-field">
          <span>To</span>
          <input
            type="number"
            min={18}
            max={100}
            value={data.age_max}
            onChange={(e) => set("age_max", e.target.value)}
          />
        </div>
      </div>
    </div>,

    // Step 3: Location
    <div className="step" key="step3">
      <h2>Where are you based?</h2>
      <p className="step-hint">Used for local suggestions and matching.</p>

      {permission !== "granted" && (
        <button
          className="location-detect-btn"
          onClick={requestLocation}
          disabled={permission === "loading"}
        >
          {permission === "loading"
            ? "Detecting..."
            : "📍 Detect my location automatically"}
        </button>
      )}

      {permission === "granted" && detectedLocation && (
        <div className="location-detected">
          <span className="detected-badge">📍 Auto-detected</span>
          <span>{detectedLocation}</span>
        </div>
      )}

      {permission === "denied" && (
        <p className="field-hint">Location access denied — type your city below.</p>
      )}

      <label>
        {permission === "granted" ? "Or enter a different location" : "Your city / region"}
      </label>
      <div className="location-input-wrap">
        <input
          type="text"
          placeholder="e.g. Dubai, UAE"
          value={locationInput}
          onChange={(e) => handleLocationInput(e.target.value)}
          onFocus={() => setShowSuggestions(true)}
          onBlur={() => setTimeout(() => setShowSuggestions(false), 200)}
          autoComplete="off"
        />
        {searchLoading && <span className="search-spinner">…</span>}
        {showSuggestions && suggestions.length > 0 && (
          <ul className="suggestions">
            {suggestions.map((s, i) => (
              <li
                key={i}
                onMouseDown={() => {
                  setLocationInput(s.short_name);
                  set("location_region", s.short_name);
                  setShowSuggestions(false);
                }}
              >
                {s.short_name}
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>,
  ];

  const isLast = step === steps.length - 1;

  return (
    <div className="onboarding-page">
      <div className="onboarding-card">
        <div className="progress-bar">
          {steps.map((_, i) => (
            <div key={i} className={`progress-dot ${i <= step ? "active" : ""}`} />
          ))}
        </div>

        {steps[step]}

        {error && <p className="submit-error">{error}</p>}

        <div className="step-actions">
          {step > 0 && (
            <button className="back-btn" onClick={() => setStep(step - 1)}>
              Back
            </button>
          )}
          <button
            className="next-btn"
            disabled={!canAdvance() || saving}
            onClick={isLast ? handleSave : () => setStep(step + 1)}
          >
            {saving ? "Saving..." : isLast ? "Let's go →" : "Next →"}
          </button>
        </div>
      </div>
    </div>
  );
}
