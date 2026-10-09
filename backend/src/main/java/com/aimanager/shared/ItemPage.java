package com.aimanager.shared;

import java.util.List;
import java.util.UUID;
import java.util.function.Function;

/** Bounded keyset pages. A cursor is an ID, never an authorization credential. */
public record ItemPage<T>(List<T> items, String nextCursor) {
    public static void validate(int limit, String cursor) {
        if (limit < 1 || limit > 100) throw DomainException.invalid("INVALID_PAGE_SIZE");
        if (cursor != null) {
            try {
                if (!UUID.fromString(cursor).toString().equals(cursor)) throw new IllegalArgumentException();
            } catch (IllegalArgumentException failure) {
                throw DomainException.invalid("INVALID_CURSOR");
            }
        }
    }

    public static <T> ItemPage<T> from(List<T> rows, int limit, Function<T, String> id) {
        boolean hasMore = rows.size() > limit;
        var page = List.copyOf(rows.subList(0, Math.min(limit, rows.size())));
        return new ItemPage<>(page, hasMore ? id.apply(page.get(page.size() - 1)) : null);
    }
}
