import { useEffect, useRef, useState } from "react";
import "./App.scss";
import { LiveAPIProvider } from "./contexts/LiveAPIContext";
import SidePanel from "./components/side-panel/SidePanel";
import AuthPage from "./components/auth/AuthPage";
import ProfilePage from "./components/profile/ProfilePage";
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

function App() {
  const videoRef = useRef<HTMLVideoElement>(null);
  const [videoStream, setVideoStream] = useState<MediaStream | null>(null);
  const [serverUrl, setServerUrl] = useState<string>(defaultUri);
  const [user, setUser] = useState<User | null | undefined>(undefined); // undefined = still loading
  const [view, setView] = useState<View>("chat");

  // Subscribe to Supabase auth state
  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setUser(data.session?.user ?? null);
    });
    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, session) => {
      setUser(session?.user ?? null);
    });
    return () => subscription.unsubscribe();
  }, []);

  // Still resolving auth state — show nothing to avoid flicker
  if (user === undefined) {
    return <div style={{ background: "#0f0f0f", minHeight: "100vh" }} />;
  }

  // Not logged in
  if (user === null) {
    return <AuthPage />;
  }

  // Profile view
  if (view === "profile") {
    return <ProfilePage userId={user.id} onBack={() => setView("chat")} />;
  }

  // Chat console (voice UI)
  return (
    <div className="App">
      <LiveAPIProvider url={serverUrl} userId={user.id}>
        <div className="streaming-console">
          <SidePanel
            videoRef={videoRef}
            supportsVideo={true}
            onVideoStreamChange={setVideoStream}
            serverUrl={serverUrl}
            userId={user.id}
            onServerUrlChange={setServerUrl}
            onUserIdChange={() => {}} // user ID is now locked to auth session
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
