package org.springframework.persistence.graph.neo4j;

import java.lang.reflect.Field;
import java.util.AbstractSet;
import java.util.Collection;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Set;

import org.aspectj.lang.reflect.FieldSignature;
import org.neo4j.graphdb.Direction;
import org.neo4j.graphdb.DynamicRelationshipType;
import org.neo4j.graphdb.GraphDatabaseService;
import org.neo4j.graphdb.Node;
import org.neo4j.graphdb.NotInTransactionException;
import org.neo4j.graphdb.Relationship;
import org.neo4j.graphdb.RelationshipType;
import org.neo4j.util.GraphDatabaseUtil;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.dao.InvalidDataAccessApiUsageException;
import org.springframework.dao.InvalidDataAccessResourceUsageException;
import org.springframework.persistence.graph.Graph;
import org.springframework.persistence.support.AbstractTypeAnnotatingMixinFields;
import org.springframework.persistence.support.EntityInstantiator;

/**
 * Aspect to turn an object annotated with GraphEntity into a graph entity using Neo4J.
 * Delegates all field access (except for fields assumed to be transient)
 * to an underlying Neo4 graph node.
 * 
 * @author Rod Johnson
 */
public aspect Neo4jNodeBacking extends AbstractTypeAnnotatingMixinFields<Graph.Entity,NodeBacked> {
	
	//-------------------------------------------------------------------------
	// Configure aspect for whole system.
	// init() method can be invoked automatically if the aspect is a Spring
	// bean, or called in user code.
	//-------------------------------------------------------------------------
	// Aspect shared Neo4J Graph Database Service
	private GraphDatabaseService graphDatabaseService;
	
	private EntityInstantiator<NodeBacked, Node> graphEntityInstantiator;
	
	private GraphDatabaseUtil graphDatabaseUtil;

	private RelationshipInfoFactory relationshipInfoFactory;

	private EntityInstantiator<RelationshipBacked, Relationship> relationshipEntityInstantiator;
	
	@Autowired
	public void init(GraphDatabaseService gds, EntityInstantiator<NodeBacked, Node> gei, EntityInstantiator<RelationshipBacked, Relationship> rei) {
		this.graphDatabaseService = gds;
		this.graphEntityInstantiator = gei;
		this.relationshipEntityInstantiator = rei;
		this.graphDatabaseUtil = new GraphDatabaseUtil(gds);
		this.relationshipInfoFactory = new RelationshipInfoFactory(graphEntityInstantiator, relationshipEntityInstantiator);
	}
	
	
	//-------------------------------------------------------------------------
	// Advise user-defined constructors of NodeBacked objects to create a new
	// Neo4J backing node
	//-------------------------------------------------------------------------
	pointcut arbitraryUserConstructorOfNodeBackedObject(NodeBacked entity) : 
		execution((@Graph.Entity *).new(..)) &&
		!execution((@Graph.Entity *).new(Node)) &&
		this(entity);
	
	
	// Create a new node in the Graph if no Node was passed in a constructor
	before(NodeBacked entity) : arbitraryUserConstructorOfNodeBackedObject(entity) {
		try {
			entity.setUnderlyingNode(graphDatabaseService.createNode());
			log.info("User-defined constructor called on class " + entity.getClass() + "; created Node [" + entity.getUnderlyingNode() +"]; " +
					"Updating metamodel");
			// TODO pull naming out into a strategy interface, todo a separate one, or the Entity Instatiator
			// graphEntityInstantiator.postEntityCreation(entity);
			postEntityCreation(entity);
		} catch(NotInTransactionException e) {
			throw new InvalidDataAccessResourceUsageException("Not in a Neo4j transaction.", e);
		}
	}

	private void postEntityCreation(NodeBacked entity) {
		Node subReference = Neo4jHelper.findSubreferenceNode(entity.getClass(), graphDatabaseService);
		entity.getUnderlyingNode().createRelationshipTo(subReference, Neo4jHelper.INSTANCE_OF_RELATIONSHIP_TYPE);
		GraphDatabaseUtil.incrementAndGetCounter(subReference, Neo4jHelper.SUBREFERENCE_NODE_COUNTER_KEY);
	}
	
	// Introduced field
	private Node NodeBacked.underlyingNode;
	
	public void NodeBacked.setUnderlyingNode(Node n) {
		this.underlyingNode = n;
	}
	
	public Node NodeBacked.getUnderlyingNode() {
		return underlyingNode;
	}
	
	public Relationship NodeBacked.relateTo(NodeBacked nb, RelationshipType type) {
		return this.underlyingNode.createRelationshipTo(nb.getUnderlyingNode(), type);
	}

	public long NodeBacked.getId() {
		return underlyingNode.getId();
	}
	
	
	//-------------------------------------------------------------------------
	// Equals and hashCode for Neo4j entities.
	// Final to prevent overriding.
	//-------------------------------------------------------------------------
	// TODO could use template method for further checks if needed
	public final boolean NodeBacked.equals(Object obj) {
		if (obj instanceof NodeBacked) {
			return this.getUnderlyingNode().equals(((NodeBacked) obj).getUnderlyingNode());
		}
		return false;
	}
	
	public final int NodeBacked.hashCode() {
		return getUnderlyingNode().hashCode();
	}


	Object around(NodeBacked entity) : entityFieldGet(entity) {	
		FieldSignature fieldSignature=(FieldSignature) thisJoinPoint.getSignature();
		Field f = fieldSignature.getField();
		
		// TODO fix arrays, TODO serialize other types as byte[] or string (for indexing, querying) via Annotation
		if (isPropertyType(f.getType())) {
			String propName = getNeo4jPropertyName(f);
			log.info("GET " + f + " <- Neo4J simple node property [" + propName + "]");
			return entity.getUnderlyingNode().getProperty(propName, null);
		}
		
		RelationshipInfo relInfo = relationshipInfoFactory.forField(f);
		Object obj = relInfo.readObject(entity);
		if (obj == null) {
			log.info("Ignored GET " + f + ": " + f.getType().getName() + " not primitive or GraphEntity");
			return proceed(entity);
		}
		return obj;
	}
	
	Object around(NodeBacked entity, Object newVal) : entityFieldSet(entity, newVal) {
		try {
			FieldSignature fieldSignature=(FieldSignature) thisJoinPoint.getSignature();
			Field f = fieldSignature.getField();
			// TODO fix arrays
			Class<?> fieldType = f.getType();
			if (isPropertyType(fieldType)) {
				String propName = getNeo4jPropertyName(f);
				entity.getUnderlyingNode().setProperty(propName, newVal);
				log.info("SET " + f + " -> Neo4J simple node property [" + propName + "] with value=[" + newVal + "]");
				return proceed(entity, newVal);
			}
			
			RelationshipInfo relInfo = relationshipInfoFactory.forField(f);
			if (relInfo == null) {
				log.info("Ignored SET " + f + ": " + f.getType().getName() + " not primitive or GraphEntity");
				return proceed(entity, newVal);
			}
			log.info("SET " + f + " -> Neo4J relationship with value=[" + newVal + "]");
			Object result = relInfo.apply(entity, newVal);
			return proceed(entity,result);
		} catch(NotInTransactionException e) {
			throw new InvalidDataAccessResourceUsageException("Not in a Neo4j transaction.", e);
		}
	}

	private boolean isPropertyType(Class<?> fieldType) {
		// todo: add array support
		return fieldType.isPrimitive()
	  		|| (fieldType.isArray() && !fieldType.getComponentType().isArray() && isPropertyType(fieldType.getComponentType()))
	  		|| fieldType.equals(String.class)
	  		|| fieldType.equals(Character.class)
	  		|| fieldType.equals(Boolean.class)
	  		|| (fieldType.getName().startsWith("java.lang") && Number.class.isAssignableFrom(fieldType));
	}
	
	private static String getNeo4jPropertyName(Field field) {
		return String.format("%s.%s",field.getDeclaringClass().getSimpleName(),field.getName());
	}
	
	public static interface RelationshipInfo {
		// Set entity field to newVal
		Object apply(NodeBacked entity, Object newVal);

		// Read object from entity field
		Object readObject(NodeBacked entity);
	}
	
	public static class RelationshipInfoFactory {
		private final EntityInstantiator<NodeBacked, Node> graphEntityInstantiator;
		private final EntityInstantiator<RelationshipBacked, Relationship> relationshipEntityInstantiator;

		public RelationshipInfoFactory(EntityInstantiator<NodeBacked,Node> graphEntityInstantiator, EntityInstantiator<RelationshipBacked, Relationship> relationshipEntityInstantiator) {
			this.graphEntityInstantiator = graphEntityInstantiator;
			this.relationshipEntityInstantiator = relationshipEntityInstantiator;
		}
		
		public RelationshipInfo forField(Field field) {
			Graph.Entity.Relationship relAnnotation = field.getAnnotation(Graph.Entity.Relationship.class);
			if (isSingleRelationshipField(field)) {
				Class<? extends NodeBacked> relatedType = (Class<? extends NodeBacked>) field.getType();
				if (relAnnotation != null) {
					return new SingleRelationshipInfo(DynamicRelationshipType.withName(relAnnotation.type()), 
							relAnnotation.direction().toNeo4jDir(), relatedType, graphEntityInstantiator);
				}
				return new SingleRelationshipInfo(DynamicRelationshipType.withName(getNeo4jPropertyName(field)), 
						Direction.OUTGOING, relatedType, graphEntityInstantiator);
			}
			if (isOneToNRelationshipField(field)) {
				return new OneToNRelationshipInfo(DynamicRelationshipType.withName(relAnnotation.type()), 
						relAnnotation.direction().toNeo4jDir(), relAnnotation.elementClass(), graphEntityInstantiator);
			}
			if (isOneToNRelationshipEntityField(field)) {
				Graph.Entity.RelationshipEntity relEntityAnnotation = field.getAnnotation(Graph.Entity.RelationshipEntity.class);
				return new OneToNRelationshipEntityInfo(DynamicRelationshipType.withName(relEntityAnnotation.type()), 
						relEntityAnnotation.direction().toNeo4jDir(), relEntityAnnotation.elementClass(), relationshipEntityInstantiator);
			}
			throw new IllegalArgumentException("Not a Neo4j relationship field: " + field);
		}

		private boolean isOneToNRelationshipEntityField(Field f) {
			if (!Iterable.class.isAssignableFrom(f.getType())) return false;
			return f.isAnnotationPresent(Graph.Entity.RelationshipEntity.class);
		}

		private static boolean isSingleRelationshipField(Field f) {
			return NodeBacked.class.isAssignableFrom(f.getType());
		}
		
		private static boolean isOneToNRelationshipField(Field f) {
			if (!Collection.class.isAssignableFrom(f.getType())) return false;
			Graph.Entity.Relationship relationship = f.getAnnotation(Graph.Entity.Relationship.class);
			return relationship != null &&  NodeBacked.class.isAssignableFrom(relationship.elementClass()) && !relationship.elementClass().equals(NodeBacked.class);
		}
	}
	
	public static class SingleRelationshipInfo implements RelationshipInfo {

		private final RelationshipType type;
		private final Direction direction;
		private final Class<? extends NodeBacked> relatedType;
		private final EntityInstantiator<NodeBacked, Node> graphEntityInstantiator;
		
		public SingleRelationshipInfo(RelationshipType type, Direction direction, Class<? extends NodeBacked> clazz, EntityInstantiator<NodeBacked, Node> graphEntityInstantiator) {
			this.type = type;
			this.direction = direction;
			this.relatedType = clazz;
			this.graphEntityInstantiator = graphEntityInstantiator;
		}

		public Object apply(NodeBacked entity, Object newVal) {
			if (newVal != null && !(newVal instanceof NodeBacked)) {
				throw new IllegalArgumentException("New value must be NodeBacked.");
			}
			Node entityNode = entity.getUnderlyingNode();
			for ( Relationship relationship : entityNode.getRelationships(type, direction) ) {
				relationship.delete();
			}
			if (newVal == null) {
				return null;
			}
			Node targetNode = ((NodeBacked) newVal).getUnderlyingNode();
			if (entityNode.equals(targetNode)) {
				throw new InvalidDataAccessApiUsageException("Cannot create circular reference.");
			}
			switch(direction) {
				case OUTGOING : entityNode.createRelationshipTo(targetNode, type); break;
				case INCOMING : targetNode.createRelationshipTo(entityNode, type); break;
				default : throw new IllegalArgumentException("invalid direction " + direction); 
			}
			return newVal;
		}

		@Override
		public Object readObject(NodeBacked entity) {
			Node entityNode = entity.getUnderlyingNode();
			if (entityNode == null) {
				throw new IllegalStateException("Entity must have a backing Node");
			}
			Relationship singleRelationship = entityNode.getSingleRelationship(type, direction);
			
			if (singleRelationship == null) {
				return null;
			}
			Node targetNode = singleRelationship.getOtherNode(entityNode);
			return graphEntityInstantiator.createEntityFromState(targetNode, relatedType);
		}
		
	}
	
	public static class OneToNRelationshipInfo implements RelationshipInfo {

		private final RelationshipType type;
		private final Direction direction;
		private final Class<? extends NodeBacked> relatedType;
		private final EntityInstantiator<NodeBacked, Node> graphEntityInstantiator;

		public OneToNRelationshipInfo(RelationshipType type, Direction direction, Class<? extends NodeBacked> elementClass, EntityInstantiator<NodeBacked, Node> graphEntityInstantiator) {
			this.type = type;
			this.direction = direction;
			this.relatedType = elementClass;
			this.graphEntityInstantiator = graphEntityInstantiator;
		}

		public Object apply(final NodeBacked entity, final Object newVal) {
			Node entityNode = entity.getUnderlyingNode();
			
			Set<Node> newNodes=new HashSet<Node>();
			if (newVal != null) {
				if (!(newVal instanceof Set)) {
					throw new IllegalArgumentException("New value must be a Set, was: " + newVal.getClass());
				}
				Set<Object> set = (Set<Object>) newVal;
				for (Object obj : set) {
					if (!(obj instanceof NodeBacked)) {
						throw new IllegalArgumentException("New value elements must be NodeBacked.");
					}
					Node newNode=((NodeBacked) obj).getUnderlyingNode();
					if (entityNode.equals(newNode)) {
						throw new InvalidDataAccessApiUsageException("Cannot create circular reference.");
					}
					newNodes.add(newNode);
				}
			}
			for ( Relationship relationship : entityNode.getRelationships(type, direction) ) {
				if (!newNodes.remove(relationship.getOtherNode(entityNode)))
					relationship.delete();
			}
			if (newVal == null) {
				return null;
			}
			
			for (Node newNode : newNodes) {
				switch(direction) {
					case OUTGOING : entityNode.createRelationshipTo(newNode, type); break;
					case INCOMING : newNode.createRelationshipTo(entityNode, type); break;
					default : throw new IllegalArgumentException("invalid direction " + direction); 
				}
			}
			return new ManagedSet<NodeBacked>(entity, newVal,this); // TODO managedSet that for each mutating method calls this apply (todo use AspectJ to handle that?)
		}
		
		@Override
		public Object readObject(NodeBacked entity) {
			Node entityNode = entity.getUnderlyingNode();
			if (entityNode == null) {
				throw new IllegalStateException("Entity must have a backing Node");
			}
			Set<NodeBacked> result = new HashSet<NodeBacked>();
			for (Relationship rel : entityNode.getRelationships(type, direction)) {
				result.add(graphEntityInstantiator.createEntityFromState(rel.getOtherNode(entityNode), relatedType));
			}
			return new ManagedSet<NodeBacked>(entity, result, this); 
		}
		
	}

	public static class OneToNRelationshipEntityInfo implements RelationshipInfo {

		private final RelationshipType type;
		private final Direction direction;
		private final Class<? extends RelationshipBacked> elementClass;
		private final EntityInstantiator<RelationshipBacked, Relationship> relationshipEntityInstantiator;

		public OneToNRelationshipEntityInfo(RelationshipType type, Direction direction, Class<? extends RelationshipBacked> elementClass, EntityInstantiator<RelationshipBacked, Relationship> relationshipEntityInstantiator) {
			this.type = type;
			this.direction = direction;
			this.elementClass = elementClass;
			this.relationshipEntityInstantiator = relationshipEntityInstantiator;
		}

		@Override
		public Object apply(NodeBacked entity, Object newVal) {
			throw new InvalidDataAccessApiUsageException("Cannot set read-only relationship entity field.");
		}

		@Override
		public Object readObject(NodeBacked entity) {
			Set<RelationshipBacked> result = new HashSet<RelationshipBacked>();
			for (Relationship rel : entity.getUnderlyingNode().getRelationships(type, direction)) {
				result.add(relationshipEntityInstantiator.createEntityFromState(rel, elementClass));
			}
			return new ManagedSet<RelationshipBacked>(entity, result, this);
		}
	}
	
	private static final class ManagedSet<T> extends AbstractSet<T> {
		private final NodeBacked entity;
		final Set<T> delegate;
		private final RelationshipInfo relationshipInfo;

		private ManagedSet(NodeBacked entity, Object newVal, RelationshipInfo relationshipInfo) {
			this.entity = entity;
			this.relationshipInfo = relationshipInfo;
			delegate = (Set<T>) newVal;
		}

		@Override
		public Iterator<T> iterator() {
			return delegate.iterator();
		}

		@Override
		public int size() {
			return delegate.size();
		}

		@Override
		public boolean add(T e) {
			boolean res = delegate.add(e);
			if (res) {
				relationshipInfo.apply(entity, delegate);
			}
			return res;
		}

		@Override
		public boolean remove(Object o) {
			boolean res = delegate.remove(o);
			if (res) {
				relationshipInfo.apply(entity, delegate);
			}
			return res;
		}
		
	}

}
