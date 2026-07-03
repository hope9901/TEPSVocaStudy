import sqlite3
import json
import uuid
import datetime

db_path = r"f:\project2\TEPSvoca\v85_20260312T133124Z.db"
json_path = r"f:\project2\TEPSMaster\Data\vocab_db_full.json"
unified_vocab_id = "unified-teps-vocab-id"

conn = sqlite3.connect(db_path)
cursor = conn.cursor()

try:
    print("Reading TEPSMaster vocabulary JSON...")
    with open(json_path, "r", encoding="utf-8") as f:
        teps_master_words = json.load(f)
    
    print(f"Loaded {len(teps_master_words)} words from JSON.")
    
    # Get current active words in DB to compare and avoid duplicates
    cursor.execute("SELECT id, word, meaning, exampleSentence, familiar FROM Corpus WHERE vocabularyId = ? AND isDeleted = 0;", (unified_vocab_id,))
    db_rows = cursor.fetchall()
    
    # Mapping lowercase word -> row info
    word_map = {row[1].strip().lower(): {
        "id": row[0],
        "word": row[1],
        "meaning": row[2],
        "exampleSentence": row[3],
        "familiar": row[4]
    } for row in db_rows}
    
    now_str = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3] + "Z"
    
    inserted_count = 0
    merged_count = 0
    
    for item in teps_master_words:
        target_word = item["target_word"].strip()
        korean_meaning = item["korean_meaning"].strip()
        category = item.get("category", "")
        level = item.get("level", 3)
        question = item.get("question", "")
        hint = item.get("hint", "")
        
        # Build complete sentence
        example_sentence = ""
        if question:
            # Replace blank with the word itself
            example_sentence = question.replace("____", target_word).strip()
            
        desc = f"Category: {category} | Level: {level} | Hint: {hint}"
        
        w_lower = target_word.lower()
        
        if w_lower in word_map:
            # Word already exists. Merge meaning and add example sentence if missing.
            db_word = word_map[w_lower]
            existing_meaning = db_word["meaning"]
            existing_sentence = db_word["exampleSentence"]
            
            # Merge meanings
            m_tokens = [t.strip() for t in existing_meaning.replace('﹒', '/').replace(',', '/').split('/') if t.strip()]
            new_tokens = [t.strip() for t in korean_meaning.replace('﹒', '/').replace(',', '/').split('/') if t.strip()]
            
            for token in new_tokens:
                if token not in m_tokens:
                    m_tokens.append(token)
            merged_meaning = "﹒".join(m_tokens)
            
            # Use the new example sentence if the old one is missing
            final_sentence = existing_sentence if (existing_sentence and len(existing_sentence) > 0) else example_sentence
            
            # Update in DB
            cursor.execute("""
                UPDATE Corpus 
                SET meaning = ?, exampleSentence = ?, desc = ?, updatedAt = ?
                WHERE id = ?;
            """, (merged_meaning, final_sentence, desc, now_str, db_word["id"]))
            
            # Update map to reflect changes in later duplicates
            word_map[w_lower]["meaning"] = merged_meaning
            word_map[w_lower]["exampleSentence"] = final_sentence
            
            merged_count += 1
        else:
            # New word. Insert it.
            new_id = str(uuid.uuid4())
            cursor.execute("""
                INSERT INTO Corpus (id, vocabularyId, word, meaning, pos, pronunciation, desc, synonym, antonym, image, familiar, isDeleted, scheduledAt, updatedAt, createdAt, exampleSentence)
                VALUES (?, ?, ?, ?, NULL, NULL, ?, NULL, NULL, NULL, 0, 0, ?, ?, ?, ?);
            """, (new_id, unified_vocab_id, target_word, korean_meaning, desc, now_str, now_str, now_str, example_sentence))
            
            # Add to map so duplicates inside the JSON itself can be merged
            word_map[w_lower] = {
                "id": new_id,
                "word": target_word,
                "meaning": korean_meaning,
                "exampleSentence": example_sentence,
                "familiar": 0
            }
            
            inserted_count += 1
            
    print(f"Import process done. New words inserted: {inserted_count}, Existing words updated/merged: {merged_count}")
    
    # Recalculate Vocabulary statistics
    cursor.execute("SELECT COUNT(*) FROM Corpus WHERE vocabularyId = ? AND isDeleted = 0;", (unified_vocab_id,))
    total_count = cursor.fetchone()[0]
    
    cursor.execute("SELECT COUNT(*) FROM Corpus WHERE vocabularyId = ? AND isDeleted = 0 AND familiar >= 3;", (unified_vocab_id,))
    n_familiar = cursor.fetchone()[0]
    n_unfamiliar = total_count - n_familiar
    
    cursor.execute("""
        UPDATE Vocabulary 
        SET total = ?, nFamiliar = ?, nUnfamiliar = ?, updatedAt = ?
        WHERE id = ?;
    """, (total_count, n_familiar, n_unfamiliar, now_str, unified_vocab_id))
    
    conn.commit()
    print(f"Database statistics updated. Total active words: {total_count} (Familiar: {n_familiar}, Unfamiliar: {n_unfamiliar})")

except Exception as e:
    conn.rollback()
    print(f"Error occurred during import: {e}")
finally:
    conn.close()
