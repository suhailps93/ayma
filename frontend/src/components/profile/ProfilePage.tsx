import { useEffect, useState } from "react";
import ReactMarkdown from "react-markdown";
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
  const [insights, setInsights] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    async function fetchData() {
      setLoading(true);
      try {
        const [profileData, insightsData] = await Promise.all([
          api.getProfile(),
          api.getInsights()
        ]);
        
        setProfile({
          ...profileData,
          community_profile: profileData.community_profile ?? null,
        });
        setInsights(insightsData);
        setError(null);
      } catch (err) {
        setError(err instanceof Error ? err.message : "Could not load profile");
      }
      setLoading(false);
    }

    fetchData();
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

  const getSectionTitle = (key: string) => {
    return key.replace(/_/g, ' ').replace(/\b\w/g, l => l.toUpperCase());
  };

  return (
    <div className="profile-page">
      <header className="profile-header">
        <button className="back-btn" onClick={onBack}>← Back</button>
        <h2>My Profile & Insights</h2>
        <span className="agent-badge">
          Managed by {profile?.agent_name ?? "Ayma"}
        </span>
      </header>

      <div className="profile-body">
        {/* Core Profile Tiers (Public/Private) */}
        <section className="profile-section">
          <div className="section-label">
            <span>Public profile</span>
            <span className="lock-status">
              {profile?.profile_public_locked ? "✎ Edited by you" : "✦ Written by AI"}
            </span>
          </div>
          <div className="profile-content markdown-content">
            {profile?.profile_public
              ? <ReactMarkdown>{profile.profile_public}</ReactMarkdown>
              : <p className="empty">Your AI matchmaker is still getting to know you. Keep chatting and your profile will fill in automatically.</p>
            }
          </div>
        </section>

        <section className="profile-section">
          <div className="section-label">
            <span>Private notes</span>
            <span className="private-badge">Only you can see this</span>
          </div>
          <div className="profile-content markdown-content">
            {profile?.profile_private
              ? <ReactMarkdown>{profile.profile_private}</ReactMarkdown>
              : <p className="empty">Nothing here yet.</p>
            }
          </div>
        </section>

        {/* Dynamic Wiki Insights */}
        {Object.entries(insights).map(([key, content]) => {
          // Skip the ones already shown in core tiers if they overlap
          // Though about_me and matching_profile are separate now
          if (!content || content.trim() === "") return null;
          
          return (
            <section key={key} className="profile-section wiki-insight">
              <div className="section-label">
                <span>{getSectionTitle(key)}</span>
                <span className="ai-badge">✦ AI Insight</span>
              </div>
              <div className="profile-content markdown-content">
                <ReactMarkdown>{content}</ReactMarkdown>
              </div>
            </section>
          );
        })}
      </div>
    </div>
  );
}
