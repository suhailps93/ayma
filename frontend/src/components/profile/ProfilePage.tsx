import { useEffect, useState } from "react";
import { api } from "../../lib/api";
import "./ProfilePage.scss";

interface UserProfile {
  id: string;
  display_name: string | null;
  profile_public: string | null;
  profile_private: string | null;
  profile_public_locked: boolean;
  agent_name: string | null;
  community_profile: string | null;
}

interface ProfilePageProps {
  onBack: () => void;
}

export default function ProfilePage({ onBack }: ProfilePageProps) {
  const [profile, setProfile] = useState<UserProfile | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    async function fetchProfile() {
      setLoading(true);
      try {
        const data = await api.getProfile();
        setProfile({
          ...data,
          community_profile: data.community_profile ?? null,
        });
        setError(null);
      } catch (err) {
        setError(err instanceof Error ? err.message : "Could not load profile");
      }
      setLoading(false);
    }

    fetchProfile();
  }, []);

  if (loading) {
    return (
      <div className="profile-page">
        <div className="profile-loading">Loading your profile...</div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="profile-page">
        <div className="profile-error">Could not load profile: {error}</div>
      </div>
    );
  }

  return (
    <div className="profile-page">
      <header className="profile-header">
        <button className="back-btn" onClick={onBack}>← Back</button>
        <h2>My Profile</h2>
        <span className="agent-badge">
          Managed by {profile?.agent_name ?? "Ayma"}
        </span>
      </header>

      <div className="profile-body">
        <section className="profile-section">
          <div className="section-label">
            <span>Public profile</span>
            <span className="lock-status">
              {profile?.profile_public_locked ? "✎ Edited by you" : "✦ Written by AI"}
            </span>
          </div>
          <div className="profile-content">
            {profile?.profile_public
              ? <p>{profile.profile_public}</p>
              : <p className="empty">Your AI matchmaker is still getting to know you. Keep chatting and your profile will fill in automatically.</p>
            }
          </div>
        </section>

        <section className="profile-section">
          <div className="section-label">
            <span>Private notes</span>
            <span className="private-badge">Only you can see this</span>
          </div>
          <div className="profile-content">
            {profile?.profile_private
              ? <p>{profile.profile_private}</p>
              : <p className="empty">Nothing here yet.</p>
            }
          </div>
        </section>
      </div>
    </div>
  );
}
