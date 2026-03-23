import { useEffect, useRef, useState } from "react";
import "./App.scss";
import { LiveAPIProvider } from "./contexts/LiveAPIContext";
import SidePanel from "./components/side-panel/SidePanel";
import AuthPage from "./components/auth/AuthPage";
import ProfilePage from "./components/profile/ProfilePage";
import OnboardingPage from "./components/onboarding/OnboardingPage";
import { api } from "./lib/api";
import { AuthUser, clearAuthSession, getAuthSession, subscribeAuthSession } from "./lib/auth";
import cn from "classnames";

// In development mode (frontend on :8501), connect to backend on :8000
const isDevelopment = window.location.port === "8501";
const defaultHost = isDevelopment
  ? `${window.location.hostname}:8000`
  : window.location.host;
const defaultUri = `${
  window.location.protocol === "https:" ? "wss:" : "ws:"
}//${defaultHost}/`;

type View = "chat" | "profile";
type AppState = "loading" | "auth" | "onboarding" | "chat";

function App() {
  const videoRef = useRef<HTMLVideoElement>(null);
  const [videoStream, setVideoStream] = useState<MediaStream | null>(null);
  const [serverUrl] = useState<string>(defaultUri);
  const [user, setUser] = useState<AuthUser | null>(getAuthSession()?.user ?? null);
  const [appState, setAppState] = useState<AppState>("loading");
  const [view, setView] = useState<View>("chat");

  useEffect(() => {
    return subscribeAuthSession(() => {
      setUser(getAuthSession()?.user ?? null);
    });
  }, []);

  useEffect(() => {
    let cancelled = false;

    async function bootstrap() {
      if (!user) {
        if (!cancelled) {
          setAppState("auth");
        }
        return;
      }

      try {
        await api.getSession();
        const data = await api.getOnboardingStatus();
        if (!cancelled) {
          setAppState(data.onboarding_complete ? "chat" : "onboarding");
        }
      } catch {
        clearAuthSession();
        if (!cancelled) {
          setAppState("auth");
        }
      }
    }

    bootstrap();
    return () => {
      cancelled = true;
    };
  }, [user]);

  if (appState === "loading") {
    return <div style={{ background: "#0f0f0f", minHeight: "100vh" }} />;
  }

  if (appState === "auth") {
    return <AuthPage />;
  }

  if (appState === "onboarding" && user) {
    return (
      <OnboardingPage
        onComplete={() => setAppState("chat")}
      />
    );
  }

  if (view === "profile" && user) {
    return <ProfilePage onBack={() => setView("chat")} />;
  }

  // Main chat UI
  return (
    <div className="App">
      <LiveAPIProvider url={serverUrl}>
        <div className="streaming-console">
          <SidePanel
            videoRef={videoRef}
            supportsVideo={true}
            onVideoStreamChange={setVideoStream}
            serverUrl={serverUrl}
            onServerUrlChange={() => {}}
          />
          <main>
            <div className="main-app-area">
              <video
                className={cn("stream", {
                  hidden: !videoRef.current || !videoStream,
                })}
                ref={videoRef}
                autoPlay
                playsInline
              />
              <div className="nav-actions">
                <button className="nav-btn" onClick={() => setView("profile")}>
                  My Profile
                </button>
                <button
                  className="nav-btn"
                  onClick={async () => {
                    try {
                      await api.logout();
                    } finally {
                      clearAuthSession();
                    }
                  }}
                >
                  Sign out
                </button>
              </div>
            </div>
          </main>
        </div>
      </LiveAPIProvider>
    </div>
  );
}

export default App;
