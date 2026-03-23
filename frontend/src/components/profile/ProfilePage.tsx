import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";
import "./ProfilePage.scss";

interface UserProfile {
  id: string;
  display_name: string | null;
  profile_public: string | null;
  profile_private: string | null;
  profile_public_locked: boolean;
  agent_name: string | null;
  community_profile: string;
}

interface ProfilePageProps {
  userId: string;
  onBack: () => void;
}

export default function ProfilePage({ userId, onBack }: ProfilePageProps) {
  const [profile, setProfile] = useState<UserProfile | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    async function fetchProfile() {
      setLoading(true);
      const { data, error } = await supabase
        .from("user_profile_safe")
        .select("id, display_name, profile_public, profile_private, profile_public_locked, agent_name, community_profile")
        .eq("id", userId)
        .single();

      if (error) {
        setError(error.message);
      } else {
        setProfile(data);
      }
      setLoading(false);
    }

    fetchProfile();
  }, [userId]);

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
