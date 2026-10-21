/// The engine's single representation of a contact, shared by the Apple and
/// markdown sides (architecture §3).
///
/// Values keep their **display form** exactly as written; equality for sync
/// purposes goes through `ComparisonKeys`, never through `==` on display text.
/// `==` here is structural and is what the codec's round-trip check uses.
public struct CanonicalContact: Hashable, Sendable {
    public var kind: ContactKind
    /// Markdown-owned headline; also mbr's primary link-match key.
    public var title: String
    public var name: PersonName
    public var aliases: [Alias]
    public var company: CompanyRef?
    public var department: String?
    public var jobTitle: String?
    public var image: ImageRef?
    public var emails: [Labeled<String>]
    public var phones: [Labeled<String>]
    public var urls: [Labeled<String>]
    public var social: [Labeled<SocialHandle>]
    public var im: [Labeled<IMHandle>]
    public var addresses: [Labeled<PostalAddress>]
    /// `dates:` (birthday first when present). Labels are required by mbr.
    public var dates: [Labeled<PartialDate>]
    public var relationships: [RelationshipRef]
    /// Tags in authored order, deduplicated.
    public var tags: [String]
    /// Apple-only fields stored under `apple:`.
    public var apple: AppleExtras
    /// The engine-owned `mdsync:` block.
    public var sync: SyncMetadata
    /// Note body (everything after the frontmatter); ↔ `CNContact.note` when entitled.
    public var body: String?
    /// Unknown top-level frontmatter keys, in authored order, untouched.
    public var passthrough: [YAMLField]

    /// Creates a contact. Only `kind` and `title` are required.
    public init(
        kind: ContactKind,
        title: String,
        name: PersonName = PersonName(),
        aliases: [Alias] = [],
        company: CompanyRef? = nil,
        department: String? = nil,
        jobTitle: String? = nil,
        image: ImageRef? = nil,
        emails: [Labeled<String>] = [],
        phones: [Labeled<String>] = [],
        urls: [Labeled<String>] = [],
        social: [Labeled<SocialHandle>] = [],
        im: [Labeled<IMHandle>] = [],
        addresses: [Labeled<PostalAddress>] = [],
        dates: [Labeled<PartialDate>] = [],
        relationships: [RelationshipRef] = [],
        tags: [String] = [],
        apple: AppleExtras = AppleExtras(),
        sync: SyncMetadata = SyncMetadata(),
        body: String? = nil,
        passthrough: [YAMLField] = []
    ) {
        self.kind = kind
        self.title = title
        self.name = name
        self.aliases = aliases
        self.company = company
        self.department = department.nonEmpty
        self.jobTitle = jobTitle.nonEmpty
        self.image = image
        self.emails = emails
        self.phones = phones
        self.urls = urls
        self.social = social
        self.im = im
        self.addresses = addresses
        self.dates = dates
        self.relationships = relationships
        self.tags = tags
        self.apple = apple
        self.sync = sync
        self.body = body
        self.passthrough = passthrough
    }

    /// The first `nickname:` alias, if any.
    public var nickname: String? {
        aliases.first { $0.label == Alias.nicknameLabel }?.name
    }

    /// The birthday entry of `dates`, if any.
    public var birthday: PartialDate? {
        dates.first { $0.label == "birthday" }?.value
    }
}
