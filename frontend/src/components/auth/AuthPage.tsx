import { useState } from "react";
import { supabase } from "../../lib/supabase";
import "./AuthPage.scss";

export default function AuthPage() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [mode, setMode] = useState<"login" | "signup">("login");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [signupDone, setSignupDone] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);

    if (mode === "login") {
      const { error } = await supabase.auth.signInWithPassword({ email, password });
      if (error) setError(error.message);
    } else {
      const { error } = await supabase.auth.signUp({ email, password });
      if (error) {
        setError(error.message);
      } else {
        setSignupDone(true);
      }
    }
    setLoading(false);
  }

  if (signupDone) {
    return (
      <div className="auth-page">
        <div className="auth-card">
          <h1>Check your email</h1>
          <p>We sent a confirmation link to <strong>{email}</strong>. Click it to activate your account, then come back and log in.</p>
          <button onClick={() => { setMode("login"); setSignupDone(false); }}>
            Back to login
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="auth-page">
      <div className="auth-card">
        <h1>Ayma</h1>
        <p className="tagline">Your personal matchmaker</p>

        <form onSubmit={handleSubmit}>
          <input
            type="email"
            placeholder="Email"
            value={email}
            onChange={e => setEmail(e.target.value)}
            required
            autoFocus
          />
          <input
            type="password"
            placeholder="Password"
            value={password}
            onChange={e => setPassword(e.target.value)}
            required
            minLength={6}
          />
          {error && <p className="error">{error}</p>}
          <button type="submit" disabled={loading}>
            {loading ? "..." : mode === "login" ? "Log in" : "Sign up"}
          </button>
        </form>

        <p className="switch">
          {mode === "login" ? (
            <>No account? <button onClick={() => setMode("signup")}>Sign up</button></>
          ) : (
            <>Have an account? <button onClick={() => setMode("login")}>Log in</button></>
          )}
        </p>
      </div>
    </div>
  );
}
