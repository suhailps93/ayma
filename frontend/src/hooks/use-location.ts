/**
 * Browser geolocation + Nominatim reverse/forward geocoding.
 *
 * reverse-geocode: coordinates → "City, Country"
 * forward-geocode: text query → list of place suggestions
 *
 * Nominatim usage policy: one request per second max, include a User-Agent.
 * We debounce the search input at 400 ms to stay within limits.
 */
import { useCallback, useEffect, useRef, useState } from "react";

export type LocationPermission = "prompt" | "granted" | "denied" | "loading";

export type PlaceSuggestion = {
  display_name: string;
  short_name: string; // "City, Country"
  lat: string;
  lon: string;
};

export type UseLocationResult = {
  permission: LocationPermission;
  detectedLocation: string | null; // city/region string, set after auto-detect
  requestLocation: () => void;     // triggers browser prompt
  searchPlaces: (query: string) => void;
  suggestions: PlaceSuggestion[];
  searchLoading: boolean;
};

const NOMINATIM = "https://nominatim.openstreetmap.org";
const UA = "AymaApp/1.0";

async function reverseGeocode(lat: number, lon: number): Promise<string> {
  const url = `${NOMINATIM}/reverse?lat=${lat}&lon=${lon}&format=json`;
  const res = await fetch(url, { headers: { "User-Agent": UA } });
  const data = await res.json();
  const { city, town, village, county, state, country } = data.address || {};
  const locality = city || town || village || county || state || "";
  return country ? `${locality}, ${country}` : locality;
}

async function forwardGeocode(query: string): Promise<PlaceSuggestion[]> {
  const url = `${NOMINATIM}/search?q=${encodeURIComponent(query)}&format=json&limit=5&addressdetails=1`;
  const res = await fetch(url, { headers: { "User-Agent": UA } });
  const data: any[] = await res.json();
  return data.map((item) => {
    const a = item.address || {};
    const locality = a.city || a.town || a.village || a.county || a.state || "";
    const short = a.country ? `${locality}, ${a.country}` : locality;
    return {
      display_name: item.display_name,
      short_name: short || item.display_name,
      lat: item.lat,
      lon: item.lon,
    };
  });
}

export function useLocation(): UseLocationResult {
  const [permission, setPermission] = useState<LocationPermission>("prompt");
  const [detectedLocation, setDetectedLocation] = useState<string | null>(null);
  const [suggestions, setSuggestions] = useState<PlaceSuggestion[]>([]);
  const [searchLoading, setSearchLoading] = useState(false);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Check existing permission state on mount
  useEffect(() => {
    if (!navigator.geolocation) return;
    navigator.permissions?.query({ name: "geolocation" }).then((status) => {
      if (status.state === "granted") {
        setPermission("granted");
        // Auto-detect silently if already granted
        navigator.geolocation.getCurrentPosition(async (pos) => {
          const loc = await reverseGeocode(pos.coords.latitude, pos.coords.longitude);
          setDetectedLocation(loc);
        });
      } else if (status.state === "denied") {
        setPermission("denied");
      }
    });
  }, []);

  const requestLocation = useCallback(() => {
    if (!navigator.geolocation) {
      setPermission("denied");
      return;
    }
    setPermission("loading");
    navigator.geolocation.getCurrentPosition(
      async (pos) => {
        setPermission("granted");
        const loc = await reverseGeocode(pos.coords.latitude, pos.coords.longitude);
        setDetectedLocation(loc);
      },
      () => {
        setPermission("denied");
      },
    );
  }, []);

  const searchPlaces = useCallback((query: string) => {
    if (debounceRef.current) clearTimeout(debounceRef.current);
    if (!query.trim()) {
      setSuggestions([]);
      return;
    }
    debounceRef.current = setTimeout(async () => {
      setSearchLoading(true);
      try {
        const results = await forwardGeocode(query);
        setSuggestions(results);
      } catch {
        setSuggestions([]);
      } finally {
        setSearchLoading(false);
      }
    }, 400);
  }, []);

  return { permission, detectedLocation, requestLocation, searchPlaces, suggestions, searchLoading };
}
