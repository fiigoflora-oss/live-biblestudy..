# React Implementation Guide: RLS Security Fixes

After applying the RLS security fixes to your Supabase database, you need to update your React components to handle the new, more restrictive policies.

---

## 1. Profile Fetching - Handle Restricted Visibility

### Change 1: User's Own Profile

**Before (permissive):**
```typescript
// Could fetch anyone's profile
const fetchUserProfile = async (userId: string) => {
  const { data, error } = await supabase
    .from('profiles')
    .select('*')
    .eq('id', userId)
    .single();
  
  return { data, error };
};
```

**After (restricted - RLS enforced):**
```typescript
// Users can only fetch their own profile or mutual group members
const fetchUserProfile = async (userId: string) => {
  const { data, error } = await supabase
    .from('profiles')
    .select('*')
    .eq('id', userId)
    .single();
  
  if (error?.code === 'PGRST116') {
    // Not found - likely a permission issue due to RLS
    console.error('Profile not accessible. User may not share a study group with you.');
    return { data: null, error };
  }
  
  return { data, error };
};
```

### Change 2: Fetch All Accessible Profiles (Own + Mutual Groups)

**New pattern:**
```typescript
// Fetch own profile
const fetchOwnProfile = async () => {
  const { data: { user } } = await supabase.auth.getUser();
  
  const { data, error } = await supabase
    .from('profiles')
    .select('*')
    .eq('id', user?.id)
    .single();
  
  return { data, error };
};

// Fetch profiles of users in mutual groups
// Note: You'll need a view or helper query since RLS filters at query time
const fetchGroupMembers = async (groupId: string) => {
  const { data, error } = await supabase
    .from('group_participants')
    .select(`
      user_id,
      profiles:user_id (
        id,
        username,
        avatar_url,
        display_name
      )
    `)
    .eq('group_id', groupId)
    .eq('status', 'active');
  
  // RLS will automatically filter out profiles of users not in your groups
  return { data, error };
};
```

### Change 3: Display User Info Safely

```typescript
interface UserProfileCardProps {
  userId: string;
  currentUserId: string;
}

export const UserProfileCard = ({ userId, currentUserId }: UserProfileCardProps) => {
  const [profile, setProfile] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const loadProfile = async () => {
      try {
        const { data, error } = await fetchUserProfile(userId);
        
        if (error) {
          if (error.code === 'PGRST116') {
            setError('This user\'s profile is not accessible to you.');
          } else {
            setError('Failed to load profile');
          }
          setProfile(null);
        } else {
          setProfile(data);
        }
      } finally {
        setLoading(false);
      }
    };

    loadProfile();
  }, [userId]);

  if (loading) return <div>Loading...</div>;
  if (error) return <div className="text-red-500">{error}</div>;
  if (!profile) return <div>Profile not found</div>;

  return (
    <div className="profile-card">
      <h2>{profile.display_name}</h2>
      <p>{profile.username}</p>
      {/* Note: Email and private settings are NOT included */}
    </div>
  );
};
```

---

## 2. Session Management - Handle Active Membership Check

### Change 1: Session Deletion

**Before (permissive):**
```typescript
const deleteSession = async (sessionId: string) => {
  const { error } = await supabase
    .from('sessions')
    .delete()
    .eq('id', sessionId);
  
  return { error };
};
```

**After (membership verified):**
```typescript
const deleteSession = async (sessionId: string) => {
  const { error } = await supabase
    .from('sessions')
    .delete()
    .eq('id', sessionId);
  
  if (error?.code === 'PGRST301') {
    // Policy violation
    return {
      error: {
        ...error,
        userMessage: 'You can only delete sessions you created and must be an active group member.'
      }
    };
  }
  
  return { error };
};
```

### Change 2: Session Creation

**Before:**
```typescript
const createSession = async (groupId: string, title: string) => {
  const { data: { user } } = await supabase.auth.getUser();
  
  const { data, error } = await supabase
    .from('sessions')
    .insert([
      {
        group_id: groupId,
        creator_id: user?.id,
        title,
        scheduled_at: new Date()
      }
    ])
    .select();
  
  return { data, error };
};
```

**After (with error handling):**
```typescript
const createSession = async (groupId: string, title: string) => {
  try {
    const { data: { user } } = await supabase.auth.getUser();
    
    if (!user) {
      return { data: null, error: { message: 'Not authenticated' } };
    }

    // Check if user is active in group before attempting insert
    const { data: membership, error: membershipError } = await supabase
      .from('group_participants')
      .select('status')
      .eq('group_id', groupId)
      .eq('user_id', user.id)
      .single();

    if (!membership || membership.status !== 'active') {
      return {
        data: null,
        error: {
          message: 'You must be an active member of the group to create sessions.'
        }
      };
    }

    // Now try to create the session
    const { data, error } = await supabase
      .from('sessions')
      .insert([
        {
          group_id: groupId,
          creator_id: user.id,
          title,
          scheduled_at: new Date()
        }
      ])
      .select();

    if (error?.code === 'PGRST301') {
      return {
        data: null,
        error: {
          message: 'Failed to create session. You may not be an active group member.'
        }
      };
    }

    return { data, error };
  } catch (err) {
    return { data: null, error: err };
  }
};
```

### Change 3: Session Deletion UI Component

```typescript
interface DeleteSessionButtonProps {
  sessionId: string;
  creatorId: string;
  groupId: string;
}

export const DeleteSessionButton = ({
  sessionId,
  creatorId,
  groupId
}: DeleteSessionButtonProps) => {
  const [isDeleting, setIsDeleting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const { user } = useAuth(); // Your auth hook

  const handleDelete = async () => {
    if (user?.id !== creatorId) {
      setError('Only the session creator can delete this session.');
      return;
    }

    setIsDeleting(true);
    setError(null);

    try {
      // Verify active membership before delete attempt
      const { data: membership } = await supabase
        .from('group_participants')
        .select('status')
        .eq('group_id', groupId)
        .eq('user_id', user.id)
        .single();

      if (!membership || membership.status !== 'active') {
        setError('You must be an active group member to delete this session.');
        setIsDeleting(false);
        return;
      }

      const { error: deleteError } = await deleteSession(sessionId);

      if (deleteError) {
        setError('Failed to delete session. You may have left the group.');
      } else {
        // Refresh sessions list or navigate away
        window.location.reload(); // or use proper state management
      }
    } catch (err) {
      setError('An error occurred while deleting the session.');
    } finally {
      setIsDeleting(false);
    }
  };

  return (
    <>
      <button
        onClick={handleDelete}
        disabled={isDeleting || user?.id !== creatorId}
        className="btn-delete"
      >
        {isDeleting ? 'Deleting...' : 'Delete Session'}
      </button>
      {error && <div className="text-red-500 text-sm mt-2">{error}</div>}
    </>
  );
};
```

---

## 3. Error Handling Patterns

### Universal RLS Error Handler

```typescript
// utils/supabaseErrors.ts

export type RLSErrorCode = 
  | 'PGRST116' // Not found (likely permissions)
  | 'PGRST301' // Policy violation
  | 'PGRST302'; // Duplicate key

export const handleSupabaseError = (error: any) => {
  if (!error) return null;

  const code = error.code as RLSErrorCode;

  switch (code) {
    case 'PGRST116':
      return {
        message: 'Resource not found or not accessible to you.',
        userFriendly: 'You don\'t have permission to access this.',
        recoverable: false
      };

    case 'PGRST301':
      return {
        message: 'Row-level security policy violation.',
        userFriendly: 'You don\'t have permission to perform this action.',
        recoverable: false
      };

    case 'PGRST302':
      return {
        message: 'Duplicate key error.',
        userFriendly: 'This resource already exists.',
        recoverable: false
      };

    default:
      return {
        message: error.message || 'Unknown error',
        userFriendly: 'An error occurred. Please try again.',
        recoverable: true
      };
  }
};

// Usage
const { error } = await supabase.from('sessions').delete()...;
const errorInfo = handleSupabaseError(error);
if (errorInfo) {
  console.error(errorInfo.message);
  showUserNotification(errorInfo.userFriendly);
}
```

---

## 4. Hook for Safe Data Fetching

```typescript
// hooks/useSafeProfileFetch.ts

export const useSafeProfileFetch = (userId: string | null) => {
  const [profile, setProfile] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!userId) return;

    const fetchProfile = async () => {
      setLoading(true);
      setError(null);

      try {
        const { data, error } = await supabase
          .from('profiles')
          .select('id, username, display_name, avatar_url') // Only public fields
          .eq('id', userId)
          .single();

        if (error) {
          if (error.code === 'PGRST116') {
            setError('Profile not accessible. You may not share a study group.');
          } else {
            setError('Failed to load profile');
          }
          setProfile(null);
        } else {
          setProfile(data);
        }
      } catch (err) {
        setError('An unexpected error occurred');
      } finally {
        setLoading(false);
      }
    };

    fetchProfile();
  }, [userId]);

  return { profile, loading, error };
};

// Usage in component
const MyComponent = ({ userId }) => {
  const { profile, loading, error } = useSafeProfileFetch(userId);

  if (loading) return <Spinner />;
  if (error) return <Alert variant="error">{error}</Alert>;
  if (!profile) return <Alert>Profile not found</Alert>;

  return <UserCard profile={profile} />;
};
```

---

## 5. Testing Your Changes

### Test Cases

```typescript
// __tests__/rls-security.test.ts

describe('RLS Security Fixes', () => {
  
  test('User A cannot read User B\'s profile if not in mutual group', async () => {
    const { data, error } = await supabase
      .from('profiles')
      .select('*')
      .eq('id', 'user-b-id')
      .single();
    
    expect(error?.code).toBe('PGRST116');
    expect(data).toBeNull();
  });

  test('User A can read User B\'s profile if in mutual group', async () => {
    // Setup: both in same group with active status
    const { data, error } = await supabase
      .from('profiles')
      .select('*')
      .eq('id', 'user-b-id')
      .single();
    
    expect(error).toBeNull();
    expect(data).not.toBeNull();
  });

  test('User cannot delete session after leaving group', async () => {
    // Setup: create session, user leaves group
    const { error } = await supabase
      .from('sessions')
      .delete()
      .eq('id', 'session-id');
    
    expect(error?.code).toBe('PGRST301');
  });

  test('is_group_member function is not executable by authenticated user', async () => {
    const { error } = await supabase.rpc('is_group_member', {
      p_user_id: 'user-id',
      p_group_id: 'group-id'
    });
    
    expect(error?.message).toContain('permission denied');
  });
});
```

---

## Summary of Changes

| Feature | Before | After | Action Required |
|---------|--------|-------|-----------------|
| Profile visibility | All profiles to any auth user | Own profile + mutual groups only | Add error handling for 403s |
| Session deletion | Creator can always delete | Creator must be active member | Check membership before delete |
| Session creation | Any auth user in group | Must be active member | Add membership check |
| `is_group_member()` function | Publicly callable | Only service role | Remove any direct calls |

---

## Deployment Checklist

- [ ] Apply migration to dev Supabase project
- [ ] Test all profile fetch operations
- [ ] Test session create/delete with edge cases
- [ ] Update error handling in all components
- [ ] Add loading states and spinners
- [ ] Deploy to staging environment
- [ ] Run end-to-end tests
- [ ] Deploy to production
- [ ] Monitor error logs for permission issues
