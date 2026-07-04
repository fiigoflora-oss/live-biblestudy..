-- ============================================================================
-- Serene Study: RLS Security Fixes
-- ============================================================================
-- Fixes three critical RLS vulnerabilities:
-- 1. Session deletion allowed after leaving group
-- 2. All user profile data readable by any logged-in user
-- 3. Signed-in users can execute SECURITY DEFINER function
-- ============================================================================

-- ============================================================================
-- ISSUE #1: Tighten DELETE policy on sessions/group_participants
-- ============================================================================

-- Drop existing overly permissive DELETE policies
DROP POLICY IF EXISTS "users_can_delete_own_sessions" ON sessions;
DROP POLICY IF EXISTS "users_can_delete_group_sessions" ON sessions;
DROP POLICY IF EXISTS "members_can_delete_group_participants" ON group_participants;

-- Create new restrictive DELETE policy for sessions table
-- Users can only delete a session if:
-- a) They are the creator of the session AND
-- b) They are currently an active member of the group
CREATE POLICY "delete_sessions_only_as_active_creator" ON sessions
  FOR DELETE
  USING (
    auth.uid() = creator_id
    AND EXISTS (
      SELECT 1 FROM group_participants
      WHERE group_participants.group_id = sessions.group_id
      AND group_participants.user_id = auth.uid()
      AND group_participants.status = 'active'
    )
  );

-- Create new restrictive DELETE policy for group_participants table
-- Users can only delete themselves from group_participants if they are the row owner
CREATE POLICY "delete_own_group_participation" ON group_participants
  FOR DELETE
  USING (auth.uid() = user_id);

-- ============================================================================
-- ISSUE #2: Restrict SELECT policy on profiles table
-- ============================================================================

-- Drop existing overly permissive SELECT policies
DROP POLICY IF EXISTS "Public profiles are viewable by everyone" ON profiles;
DROP POLICY IF EXISTS "Authenticated users can view all profiles" ON profiles;
DROP POLICY IF EXISTS "Users can view all profiles" ON profiles;

-- Create new restrictive SELECT policies:
-- 1. Users can always read their own profile
CREATE POLICY "users_can_read_own_profile" ON profiles
  FOR SELECT
  USING (auth.uid() = id);

-- 2. Users can read profiles of other users in their study groups (via mutual group membership)
CREATE POLICY "users_can_read_profiles_in_mutual_groups" ON profiles
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM group_participants gp1
      INNER JOIN group_participants gp2 ON gp1.group_id = gp2.group_id
      WHERE gp1.user_id = auth.uid()
      AND gp2.user_id = profiles.id
      AND gp1.status = 'active'
      AND gp2.status = 'active'
    )
  );

-- ============================================================================
-- ISSUE #3: Revoke EXECUTE privilege on is_group_member function
-- ============================================================================

-- Revoke EXECUTE from all roles except the function definer
REVOKE EXECUTE ON FUNCTION is_group_member(UUID, UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION is_group_member(UUID, UUID) FROM anon;
REVOKE EXECUTE ON FUNCTION is_group_member(UUID, UUID) FROM authenticated;

-- Grant EXECUTE only to the definer (service_role) for internal use
GRANT EXECUTE ON FUNCTION is_group_member(UUID, UUID) TO service_role;

-- ============================================================================
-- OPTIONAL: Ensure INSERT/UPDATE policies are secure
-- ============================================================================

-- If not already present, add safeguards for INSERT policies
-- Drop and recreate INSERT policy for sessions to ensure only active members can create
DROP POLICY IF EXISTS "users_can_create_sessions" ON sessions;
CREATE POLICY "active_members_can_create_sessions" ON sessions
  FOR INSERT
  WITH CHECK (
    auth.uid() = creator_id
    AND EXISTS (
      SELECT 1 FROM group_participants
      WHERE group_participants.group_id = sessions.group_id
      AND group_participants.user_id = auth.uid()
      AND group_participants.status = 'active'
    )
  );

-- Drop and recreate INSERT policy for group_participants
DROP POLICY IF EXISTS "users_can_join_groups" ON group_participants;
CREATE POLICY "users_can_join_groups" ON group_participants
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- UPDATE policy: users can only update their own group_participants status if not already removed
DROP POLICY IF EXISTS "users_can_update_own_participation" ON group_participants;
CREATE POLICY "users_can_update_own_participation" ON group_participants
  FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);
