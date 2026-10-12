#include "CFArtworkTags.h"
#include <fileref.h>
#include <tfile.h>
#include <tvariant.h>
#include <tpropertymap.h>
#include <mpegfile.h>
#include <id3v2tag.h>
#include <wavfile.h>
#include <aifffile.h>
#include <CoreFoundation/CoreFoundation.h>
#include <cstdio>
#include <exception>

static TagLib::String nativeString(const TagLib::ByteVector &bytes) {
    auto string = CFStringCreateWithBytes(nullptr, reinterpret_cast<const UInt8 *>(bytes.data()), bytes.size(), kCFStringEncodingUTF8, false);
    if(!string) string = CFStringCreateWithBytes(nullptr, reinterpret_cast<const UInt8 *>(bytes.data()), bytes.size(), kCFStringEncodingMacRoman, false);
    if(!string) return {};
    std::string utf8(CFStringGetMaximumSizeForEncoding(CFStringGetLength(string), kCFStringEncodingUTF8) + 1, '\0');
    CFStringGetCString(string, utf8.data(), utf8.size(), kCFStringEncodingUTF8);
    CFRelease(string);
    return TagLib::String(utf8.c_str(), TagLib::String::UTF8);
}

static void carryAIFFText(TagLib::RIFF::AIFF::File *file) {
    // AIFF may have NAME/AUTH/ANNO text outside ID3. Adding an ID3 cover can
    // make players prefer ID3, so mirror those values without changing the chunks.
    for(TagLib::offset_t offset = 12; offset + 8 <= file->length();) {
        file->seek(offset);
        const auto header = file->readBlock(8);
        if(header.size() != 8) break;
        const auto size = header.toUInt(4, true);
        if(offset + 8 + size > file->length()) break;
        const auto name = header.mid(0, 4);
        if(size <= 1024 * 1024 && (name == "NAME" || name == "AUTH" || name == "ANNO" || name == "(c) ")) {
            const auto value = nativeString(file->readBlock(size));
            auto tag = file->tag();
            if(name == "NAME" && tag->title().isEmpty()) tag->setTitle(value);
            if(name == "AUTH" && tag->artist().isEmpty()) tag->setArtist(value);
            if(name == "ANNO" && tag->comment().isEmpty()) tag->setComment(value);
            if(name == "(c) " && !tag->properties().contains("COPYRIGHT")) {
                auto props = tag->properties(); props["COPYRIGHT"] = value; tag->setProperties(props);
            }
        }
        offset += 8 + size + (size & 1);
    }
}

bool cf_artwork_write(const char *path, const unsigned char *data, size_t size,
                      const char *mime, int width, int height, char *error, size_t errorSize) {
    auto fail = [&](const char *message) {
        if(error && errorSize) std::snprintf(error, errorSize, "%s", message);
        return false;
    };
    try {
        if(!data || !size || size >= 12 * 1024 * 1024) return fail("The artwork is empty or too large for an embedded tag.");
        const TagLib::ByteVector image(reinterpret_cast<const char *>(data), static_cast<unsigned int>(size));
        TagLib::PropertyMap expected;
        {
            TagLib::FileRef ref(path, false);
            if(ref.isNull() || !ref.file()->isValid()) return fail("The audio file is damaged or this format cannot store cover art.");
            if(ref.file()->readOnly()) return fail("The audio file is read-only.");
            if(auto aiff = dynamic_cast<TagLib::RIFF::AIFF::File *>(ref.file())) carryAIFFText(aiff);
            const auto properties = ref.file()->properties();
            // A new ID3v2 cover must not hide an existing ID3v1/RIFF text tag.
            if(auto mp3 = dynamic_cast<TagLib::MPEG::File *>(ref.file())) {
                auto tag = mp3->ID3v2Tag(true);
                if(tag->isEmpty()) tag->setProperties(properties);
            }
            if(auto wav = dynamic_cast<TagLib::RIFF::WAV::File *>(ref.file())) {
                auto tag = wav->ID3v2Tag();
                if(tag && tag->isEmpty()) tag->setProperties(properties);
            }
            TagLib::List<TagLib::VariantMap> pictures;
            pictures.append({{"data", image}, {"mimeType", TagLib::String(mime)},
                             {"pictureType", TagLib::String("Front Cover")},
                             {"width", width}, {"height", height}, {"colorDepth", 32}});
            // Keep explicitly labelled back covers/booklets. Untyped MP4 pictures and
            // legacy "Other" covers are replaced, so players see the new front cover.
            for(const auto &picture : ref.file()->complexProperties("PICTURE")) {
                auto type = picture.value("pictureType").value<TagLib::String>();
                if(!type.isEmpty() && type != "Front Cover" && type != "Other") pictures.append(picture);
            }
            if(!ref.file()->setComplexProperties("PICTURE", pictures)) return fail("This audio format cannot store cover art.");
            expected = ref.file()->properties();
            // Pictures appear in unsupportedData (APIC/covr), so compare text values
            // before the edit, then the full resulting map after reopening.
            if(expected.size() != properties.size()) return fail("Existing metadata changed; the original file was kept.");
            for(const auto &[key, values] : properties)
                if(expected.value(key) != values) return fail("Existing metadata changed; the original file was kept.");
            bool saved;
            if(auto mp3 = dynamic_cast<TagLib::MPEG::File *>(ref.file()))
                saved = mp3->save(TagLib::MPEG::File::AllTags, TagLib::MPEG::File::StripNone,
                                  TagLib::ID3v2::v4, TagLib::MPEG::File::DoNotDuplicate);
            else saved = ref.save();
            if(!saved) return fail("Couldn’t save the artwork tags.");
        }
        // Close the writer before reopening, flushing same-size buffered overwrites.
        TagLib::FileRef check(path, false);
        if(check.isNull() || !check.file()->isValid()) return fail("The updated file could not be verified.");
        if(check.file()->properties() != expected) return fail("Existing metadata changed; the original file was kept.");
        const auto savedPictures = check.file()->complexProperties("PICTURE");
        if(savedPictures.isEmpty() || savedPictures.front().value("data").value<TagLib::ByteVector>() != image)
            return fail("The embedded artwork could not be verified.");
        return true;
    } catch(const std::exception &e) { return fail(e.what()); }
    catch(...) { return fail("Unexpected error writing artwork tags."); }
}
