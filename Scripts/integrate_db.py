import sqlite3
import uuid
import datetime

db_path = r"f:\project2\TEPSvoca\v85_20260312T133124Z.db"
conn = sqlite3.connect(db_path)
cursor = conn.cursor()

# Enable foreign keys just in case, but we will handle integrity manually
cursor.execute("PRAGMA foreign_keys = ON;")

try:
    print("Starting vocabulary integration process...")
    
    # 1. Check bookcase id to assign unified vocabulary
    cursor.execute("SELECT bookcaseId FROM Vocabulary WHERE isDeleted = 0 LIMIT 1;")
    bookcase_row = cursor.fetchone()
    bookcase_id = bookcase_row[0] if bookcase_row else "11f0-9c6f-e9d61630-b84a-4fec44cfd82a"
    
    # 2. Create the unified Vocabulary entry if it doesn't exist
    unified_vocab_id = "unified-teps-vocab-id"
    now_str = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3] + "Z"
    
    cursor.execute("SELECT id FROM Vocabulary WHERE id = ?;", (unified_vocab_id,))
    if cursor.fetchone():
        print("Unified vocabulary entry already exists. Updating its metadata...")
        cursor.execute("""
            UPDATE Vocabulary 
            SET name = '텝스 통합 단어장', bookcaseId = ?, isDeleted = 0, updatedAt = ?
            WHERE id = ?;
        """, (bookcase_id, now_str, unified_vocab_id))
    else:
        print("Creating new unified vocabulary entry...")
        cursor.execute("""
            INSERT INTO Vocabulary (id, bookcaseId, name, desc, wordLang, meaningLang, total, nFamiliar, nUnfamiliar, price, isShowSchedule, isSharable, isDeleted, updatedAt, createdAt)
            VALUES (?, ?, '텝스 통합 단어장', '통합된 텝스 단어장입니다.', 'englishUs', 'korean', 0, 0, 0, 0, 1, 1, 0, ?, ?);
        """, (unified_vocab_id, bookcase_id, now_str, now_str))

    # 3. Mark existing active vocabularies as deleted (except the unified one)
    cursor.execute("""
        UPDATE Vocabulary 
        SET isDeleted = 1, updatedAt = ? 
        WHERE id != ? AND isDeleted = 0;
    """, (now_str, unified_vocab_id))

    # 4. Fetch all active (isDeleted = 0) words from Corpus
    cursor.execute("""
        SELECT id, vocabularyId, word, meaning, pos, pronunciation, desc, synonym, antonym, image, familiar, exampleSentence, createdAt 
        FROM Corpus 
        WHERE isDeleted = 0;
    """)
    active_words = cursor.fetchall()
    print(f"Fetched {len(active_words)} active words from Corpus.")

    # Group words by their lowercase spelling to detect duplicates
    word_groups = {}
    for row in active_words:
        # row: (id, vocabularyId, word, meaning, pos, ...)
        w_lower = row[2].strip().lower()
        if w_lower not in word_groups:
            word_groups[w_lower] = []
        word_groups[w_lower].append(row)

    print(f"Found {len(word_groups)} unique words after case-insensitive grouping.")

    # Process and merge
    to_update_representative = []  # list of tuples: (new_meaning, new_vocab_id, familiar, id)
    to_delete_ids = []

    for w_lower, group in word_groups.items():
        # Pick the first one as representative
        rep = group[0]
        rep_id = rep[0]
        rep_word = rep[2]
        
        # Merge meanings
        meanings = []
        for row in group:
            m = row[3]
            if m:
                # Split meanings by common delimiters to deduplicate individual meaning tokens
                tokens = [t.strip() for t in m.replace('﹒', '/').replace(',', '/').split('/') if t.strip()]
                for token in tokens:
                    if token not in meanings:
                        meanings.append(token)
        
        merged_meaning = "﹒".join(meanings)  # Using the original '﹒' separator or ','
        
        # Use max familiarity among the group
        max_familiar = -1
        for row in group:
            fam = row[10]
            if fam is not None and fam > max_familiar:
                max_familiar = fam
                
        # Representative updates
        to_update_representative.append((merged_meaning, unified_vocab_id, max_familiar, rep_id))
        
        # Others in the group are marked for deletion
        for row in group[1:]:
            to_delete_ids.append(row[0])

    print(f"Updating {len(to_update_representative)} representative rows...")
    # Batch update representatives
    cursor.executemany("""
        UPDATE Corpus 
        SET meaning = ?, vocabularyId = ?, familiar = ?, isDeleted = 0, updatedAt = ?
        WHERE id = ?;
    """, [(u[0], u[1], u[2], now_str, u[3]) for u in to_update_representative])

    # Delete or mark as deleted the duplicated rows and old unused words
    # To keep DB clean, we can hard-delete the duplicate rows and deleted rows.
    # We will soft delete first or hard-delete? Let's soft-delete (isDeleted = 1) for safety, or hard delete to keep DB light.
    # Let's soft delete (isDeleted = 1) first to avoid foreign key issues.
    if to_delete_ids:
        print(f"Marking {len(to_delete_ids)} duplicate rows as deleted...")
        # Chunking delete ids just in case there are many
        chunk_size = 500
        for i in range(0, len(to_delete_ids), chunk_size):
            chunk = to_delete_ids[i:i+chunk_size]
            cursor.execute(f"UPDATE Corpus SET isDeleted = 1, updatedAt = ? WHERE id IN ({','.join(['?']*len(chunk))});", [now_str] + chunk)

    # Also make sure all other words not updated (e.g. from previously deleted vocabularies or already deleted words) are indeed deleted
    cursor.execute("""
        UPDATE Corpus 
        SET isDeleted = 1, updatedAt = ? 
        WHERE vocabularyId != ? AND id NOT IN (SELECT id FROM Corpus WHERE vocabularyId = ?);
    """, (now_str, unified_vocab_id, unified_vocab_id))

    # Update Vocabulary total count
    cursor.execute("SELECT COUNT(*) FROM Corpus WHERE vocabularyId = ? AND isDeleted = 0;", (unified_vocab_id,))
    total_active_count = cursor.fetchone()[0]
    
    # Calculate familiar and unfamiliar
    cursor.execute("SELECT COUNT(*) FROM Corpus WHERE vocabularyId = ? AND isDeleted = 0 AND familiar >= 3;", (unified_vocab_id,))
    n_familiar = cursor.fetchone()[0]
    n_unfamiliar = total_active_count - n_familiar

    cursor.execute("""
        UPDATE Vocabulary 
        SET total = ?, nFamiliar = ?, nUnfamiliar = ? 
        WHERE id = ?;
    """, (total_active_count, n_familiar, n_unfamiliar, unified_vocab_id))

    conn.commit()
    print("Database integration completed successfully!")
    print(f"Unified vocabulary active words count: {total_active_count} (Familiar: {n_familiar}, Unfamiliar: {n_unfamiliar})")

except Exception as e:
    conn.rollback()
    print(f"Error occurred during integration: {e}")
finally:
    conn.close()
