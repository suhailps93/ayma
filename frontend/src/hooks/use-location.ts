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
import { api } from "../lib/api";

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
          const result = await api.reverseLocation(pos.coords.latitude, pos.coords.longitude);
          const loc = result.location;
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
        const result = await api.reverseLocation(pos.coords.latitude, pos.coords.longitude);
        const loc = result.location;
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
        const results = await api.searchLocation(query);
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
