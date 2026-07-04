# Quick Start: Deploy RLS Security Fixes

## 📋 What Changed?

Three critical RLS (Row-Level Security) vulnerabilities have been fixed in your Supabase database:

1. ✅ **Session Deletion Protection** - Users can't delete sessions after leaving a group
2. ✅ **Profile Privacy** - User profiles only visible to mutual group members
3. ✅ **Function Security** - `is_group_member()` function not callable by authenticated users

---

## 🚀 Deployment Steps

### Step 1: Review the Changes
All files are on the branch: `security/fix-rls-vulnerabilities`

- **SQL Migration:** `supabase/migrations/20260704000000_fix_rls_vulnerabilities.sql`
- **Security Docs:** `docs/SECURITY_FIXES.md`
- **React Guide:** `docs/REACT_IMPLEMENTATION_GUIDE.md`

### Step 2: Apply Migration to Supabase

#### Option A: Using Supabase Dashboard (Easiest)
1. Go to [Supabase Dashboard](https://app.supabase.com)
2. Select your project
3. Go to **SQL Editor**
4. Create a new query
5. Copy & paste the contents of `supabase/migrations/20260704000000_fix_rls_vulnerabilities.sql`
6. Click **Run**
7. Verify no errors appear

#### Option B: Using Supabase CLI
```bash
# Install CLI if not already installed
npm install -g supabase

# Pull the latest migrations
supabase db pull

# Push migrations to your project
supabase db push

# Or run a specific migration
supabase db push --dry-run  # Preview first
```

### Step 3: Verify Migration Applied
Run this SQL to confirm policies exist:
```sql
-- Check DELETE policies on sessions
SELECT * FROM pg_policies WHERE tablename = 'sessions' AND policyname LIKE '%delete%';

-- Check SELECT policies on profiles
SELECT * FROM pg_policies WHERE tablename = 'profiles' AND policyname LIKE '%read%';

-- Check function permissions
SELECT has_function_privilege('authenticated', 'is_group_member(uuid, uuid)', 'EXECUTE');
-- Should return: f (false)
```

### Step 4: Update React App
Follow the guide in `docs/REACT_IMPLEMENTATION_GUIDE.md` to update your components:

Key areas to update:
- Profile fetching functions
- Session deletion handlers
- Error handling for RLS violations
- User profile display components

### Step 5: Test Everything
```bash
# Run your test suite
npm test

# Or manually test:
# 1. Load your own profile - should work ✅
# 2. Load a non-group member's profile - should fail ✅
# 3. Delete a session you created while active in group - should work ✅
# 4. Delete a session after leaving group - should fail ✅
```

---

## 🔍 What to Look For

### Before Migration (VULNERABLE)
```
❌ Users can see all user profiles (privacy leak)
❌ Users can delete sessions even after leaving group
❌ Authenticated users can call is_group_member() function
```

### After Migration (SECURE)
```
✅ Users only see own profile + mutual group members
✅ Session deletion requires active group membership
✅ Only service_role can execute is_group_member()
```

---

## 📊 Error Codes You May See

After migration, expect these errors when RLS policies prevent an action:

| Error Code | Meaning | What To Do |
|-----------|---------|-----------|
| `PGRST116` | Not found (permission denied) | User doesn't have access to this resource |
| `PGRST301` | Policy violation | User tried to perform forbidden action |

These are **expected and secure**. Handle them gracefully in your React app.

---

## 🐛 Troubleshooting

### "Migration Failed" Error
- Check that your Supabase project is active
- Verify you have admin/owner permissions
- Check the error message for specific policy name conflicts
- If policies already exist with different names, drop them first

### "is_group_member function not found" Error
- The function may not exist in your schema yet
- Create it with `SECURITY DEFINER` before running migration
- See: `docs/SECURITY_FIXES.md` for more details

### React App Shows "Profile Not Accessible" Everywhere
- This is expected behavior with the new RLS
- Check that users are in the same study group
- Verify their `group_participants.status = 'active'`
- Update React components per `docs/REACT_IMPLEMENTATION_GUIDE.md`

---

## ⏮️ Rollback (if needed)

If something goes wrong, you can rollback by recreating old policies:

```sql
-- WARNING: This restores the VULNERABLE policies
-- Only use if absolutely necessary

-- Drop new restrictive policies
DROP POLICY IF EXISTS "delete_sessions_only_as_active_creator" ON sessions;
DROP POLICY IF EXISTS "users_can_read_own_profile" ON profiles;
DROP POLICY IF EXISTS "users_can_read_profiles_in_mutual_groups" ON profiles;

-- Recreate old permissive policies (NOT RECOMMENDED)
CREATE POLICY "users_can_delete_own_sessions" ON sessions
  FOR DELETE USING (auth.uid() = creator_id);

CREATE POLICY "authenticated_can_read_all_profiles" ON profiles
  FOR SELECT USING (auth.role() = 'authenticated');
```

---

## 📞 Need Help?

1. **Review the docs:**
   - `docs/SECURITY_FIXES.md` - Technical details
   - `docs/REACT_IMPLEMENTATION_GUIDE.md` - Code examples

2. **Check Supabase Logs:**
   - Supabase Dashboard → Logs → Database
   - Look for policy-related errors

3. **Test in Development First:**
   - Apply migration to dev project
   - Verify all functionality works
   - Then deploy to production

---

## ✅ Deployment Checklist

- [ ] Read `SECURITY_FIXES.md` to understand changes
- [ ] Backup your Supabase database
- [ ] Apply migration to dev environment
- [ ] Test all CRUD operations in React app
- [ ] Update React error handling per guide
- [ ] Deploy updated React code
- [ ] Apply migration to production Supabase
- [ ] Monitor logs for errors (first 24 hours)
- [ ] Mark issue as resolved

---

**Status:** Ready for deployment  
**Branch:** `security/fix-rls-vulnerabilities`  
**Files Modified:** 3 SQL policies + React components + docs
