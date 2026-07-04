# Serene Study: RLS Security Fixes

## Overview
This document describes three critical Row-Level Security (RLS) vulnerabilities that were fixed in the Supabase database schema.

---

## Vulnerability #1: Session Deletion After Leaving Group

### Problem
Users who left a study group could still delete sessions they shouldn't have access to. A user could:
- Leave a group (removing themselves from `group_participants`)
- Still execute DELETE operations on sessions from that group

### Root Cause
DELETE policies on the `sessions` table did not verify that the user was an active group member at the time of deletion.

### Fix Applied
**Policy Name:** `delete_sessions_only_as_active_creator`

```sql
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
```

**Requirements:**
- User must be the creator (`creator_id`)
- User must be an active member of the group (`status = 'active'`)

### Testing
```sql
-- This should FAIL if user is not an active group member
DELETE FROM sessions WHERE id = 'session-123';
```

---

## Vulnerability #2: All User Profile Data Readable by Any Logged-In User

### Problem
The `profiles` table had an overly permissive SELECT policy that allowed any authenticated user to read all rows, exposing:
- Email addresses
- Private settings
- Personal information
- Profile data of unrelated users

### Root Cause
RLS policy used `authenticated` role with blanket SELECT access without filtering by user identity or relationships.

### Fix Applied
Two restrictive SELECT policies replace the old one:

**Policy 1: Personal Profile Access**
```sql
CREATE POLICY "users_can_read_own_profile" ON profiles
  FOR SELECT
  USING (auth.uid() = id);
```
- Users can read their own profile row

**Policy 2: Mutual Group Member Access**
```sql
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
```
- Users can read profiles of other users in their mutual study groups
- Both users must have `status = 'active'` in the group

### Testing
```sql
-- User A's perspective:
SELECT * FROM profiles;
-- Returns: User A's own profile + profiles of users in User A's active groups

-- If User B is not in any of User A's groups:
-- User B's full profile is NOT visible to User A
```

---

## Vulnerability #3: Signed-In Users Can Execute SECURITY DEFINER Function

### Problem
The `is_group_member()` function is declared as `SECURITY DEFINER`, which allows it to bypass RLS policies. However, the EXECUTE privilege was not properly restricted, meaning:
- Any authenticated user could call the function directly
- A malicious user could potentially abuse or manipulate it
- The function's logic was exposed to all authenticated users

### Root Cause
EXECUTE privilege was not revoked from `authenticated`, `anon`, and `PUBLIC` roles.

### Fix Applied
```sql
-- Revoke from all public/user roles
REVOKE EXECUTE ON FUNCTION is_group_member(UUID, UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION is_group_member(UUID, UUID) FROM anon;
REVOKE EXECUTE ON FUNCTION is_group_member(UUID, UUID) FROM authenticated;

-- Grant only to service role (for internal use)
GRANT EXECUTE ON FUNCTION is_group_member(UUID, UUID) TO service_role;
```

**Result:**
- Only the `service_role` (Supabase internal operations) can execute the function
- RLS policies and database triggers can still invoke it via the definer context
- Authenticated users cannot call it directly

### Testing
```sql
-- This should return an error for authenticated users:
-- ERROR: permission denied for function is_group_member
SELECT is_group_member('user-id'::UUID, 'group-id'::UUID);
```

---

## Additional Security Improvements

### Sessions: INSERT Policy
Only active group members who are the creator can insert new sessions:
```sql
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
```

### Group Participants: DELETE Policy
Users can only remove themselves:
```sql
CREATE POLICY "delete_own_group_participation" ON group_participants
  FOR DELETE
  USING (auth.uid() = user_id);
```

### Group Participants: UPDATE Policy
Users can only update their own participation record:
```sql
CREATE POLICY "users_can_update_own_participation" ON group_participants
  FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);
```

---

## Migration Path

1. **Review the migration file:** `supabase/migrations/20260704000000_fix_rls_vulnerabilities.sql`
2. **Test in development:** Apply the migration to your dev Supabase project first
3. **Verify functionality:** Test all CRUD operations in your React app
4. **Deploy to staging:** Run against staging database
5. **Deploy to production:** Run the migration on production Supabase project

## Rollback (if needed)

If you need to rollback, create a new migration that recreates the old policies:
```bash
supabase db push --dry-run  # Preview changes
supabase db reset            # Reset to last known good state
```

---

## Impact on React Application

### Changes Required:

1. **Profile Queries**
   - Before: Could fetch any user's profile
   - After: Only fetch your own profile or users in mutual groups

2. **Session Deletion**
   - Before: Creators could delete anytime
   - After: Only active group members who are creators can delete

3. **Error Handling**
   - Add handling for RLS policy violations (403 errors)
   - Display user-friendly error messages

### Example React Updates:

```typescript
// OLD: Fetch all profiles (now will be filtered by RLS)
const { data: profiles } = await supabase
  .from('profiles')
  .select('*');

// NEW: Only user's own profile + mutual group members (RLS enforces this)
const { data: ownProfile } = await supabase
  .from('profiles')
  .select('*')
  .eq('id', userId);  // RLS will still apply

// Session deletion now requires active membership
const { error } = await supabase
  .from('sessions')
  .delete()
  .eq('id', sessionId);

if (error?.code === 'PGRST301') {
  // Policy violation - user is not an active group member
  console.error('You cannot delete this session');
}
```

---

## Verification Checklist

- [ ] Migration applied to Supabase project
- [ ] No SQL errors in migration execution
- [ ] Users can read their own profile
- [ ] Users can read profiles of mutual group members only
- [ ] Users cannot read profiles of non-group members
- [ ] Only active creators can delete sessions
- [ ] Users cannot execute `is_group_member()` directly
- [ ] All React app functionality tested
- [ ] No unexpected 403 errors in production

---

## References

- [Supabase RLS Documentation](https://supabase.com/docs/guides/auth/row-level-security)
- [PostgreSQL GRANT/REVOKE](https://www.postgresql.org/docs/current/sql-grant.html)
- [Supabase Security Best Practices](https://supabase.com/docs/guides/auth/row-level-security-best-practices)
