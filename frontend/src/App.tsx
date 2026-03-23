import { useEffect, useRef, useState } from "react";
import "./App.scss";
import { LiveAPIProvider } from "./contexts/LiveAPIContext";
import SidePanel from "./components/side-panel/SidePanel";
import AuthPage from "./components/auth/AuthPage";
import ProfilePage from "./components/profile/ProfilePage";
import OnboardingPage from "./components/onboarding/OnboardingPage";
import { supabase } from "./lib/supabase";
import type { User } from "@supabase/supabase-js";
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
  const [user, setUser] = useState<User | null>(null);
  const [appState, setAppState] = useState<AppState>("loading");
  const [view, setView] = useState<View>("chat");

  // Subscribe to Supabase auth state
  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      const u = data.session?.user ?? null;
      setUser(u);
      if (!u) {
        setAppState("auth");
      } else {
        checkOnboarding(u.id);
      }
    });

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, session) => {
      const u = session?.user ?? null;
      setUser(u);
      if (!u) {
        setAppState("auth");
      } else {
        checkOnboarding(u.id);
      }
    });
    return () => subscription.unsubscribe();
  }, []);

  async function checkOnboarding(userId: string) {
    const { data } = await supabase
      .from("user_profile_safe")
      .select("onboarding_complete")
      .eq("id", userId)
      .single();
    setAppState(data?.onboarding_complete ? "chat" : "onboarding");
  }

  if (appState === "loading") {
    return <div style={{ background: "#0f0f0f", minHeight: "100vh" }} />;
  }

  if (appState === "auth") {
    return <AuthPage />;
  }

  if (appState === "onboarding" && user) {
    return (
      <OnboardingPage
        userId={user.id}
        onComplete={() => setAppState("chat")}
      />
    );
  }

  if (view === "profile" && user) {
    return <ProfilePage userId={user.id} onBack={() => setView("chat")} />;
  }

  // Main chat UI
  return (
    <div className="App">
      <LiveAPIProvider url={serverUrl} userId={user!.id}>
        <div className="streaming-console">
          <SidePanel
            videoRef={videoRef}
            supportsVideo={true}
            onVideoStreamChange={setVideoStream}
            serverUrl={serverUrl}
            userId={user!.id}
            onServerUrlChange={() => {}}
            onUserIdChange={() => {}}
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
                  onClick={() => supabase.auth.signOut()}
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
